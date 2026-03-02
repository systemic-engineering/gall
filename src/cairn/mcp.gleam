/// Cairn MCP protocol handler.
///
/// Transport-agnostic. Parses JSON-RPC, dispatches tools, returns:
///   - the next state
///   - the JSON response string to send (None = notification, no reply)
///   - the newly created Fragment (None = no Fragment this call)
///
/// The orchestrator (cairn.gleam) owns the socket I/O and disk writes.
/// It calls handle/2 on each incoming message and acts on the outputs.
///
/// Protocol:
///   client → initialize(clientInfo.name = nickname)
///   server → capabilities + tool list
///   client → tools/call: observe | decide | act | commit
///   client exits → cairn verifies store + commits session
///
/// The nickname from initialize becomes Author("<nickname>@systemic.engineering")
/// on every Fragment in the session. Identity is a protocol requirement.
import fragmentation
import cairn/json
import cairn/session
import cairn/tools
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

pub type State {
  Uninitialized
  Ready(session: session.Session)
}

// ---------------------------------------------------------------------------
// Handle
// ---------------------------------------------------------------------------

/// Handle one JSON-RPC message.
/// Returns #(next_state, maybe_response_json, maybe_new_fragment).
///
/// maybe_response_json: Some(json) = send to client; None = notification (no reply)
/// maybe_new_fragment:  Some(frag) = write to store immediately; None = no new fragment
pub fn handle(
  state: State,
  json: String,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let method = extract_field(json, "method")
  let id = extract_field(json, "id")

  case method {
    "initialize" -> handle_initialize(state, id, json)
    "notifications/initialized" -> #(state, None, [])
    "tools/list" -> #(
      state,
      Some(make_response(id, tools.mcp_tools_json())),
      [],
    )
    "tools/call" -> handle_tool_call(state, id, json)
    _ -> #(
      state,
      Some(make_error(id, -32_601, "method not found: " <> method)),
      [],
    )
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handle_initialize(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let nickname = extract_nested(json, "clientInfo", "name")
  let client_version = extract_nested(json, "clientInfo", "version")
  let protocol_version = extract_field(json, "protocolVersion")
  let author = nickname <> "@systemic.engineering"
  let config = session.SessionConfig(author: author, name: "cairn-session")
  let s = session.new(config)

  // Record session provenance as a @meta Fragment — written to store immediately.
  // Everything cairn knows at the moment the agent connected.
  let meta = meta_fragment(author, client_version, protocol_version)

  let response =
    make_response(
      id,
      "{\"protocolVersion\":\"2024-11-05\","
        <> "\"capabilities\":{\"tools\":{}},"
        <> "\"serverInfo\":{\"name\":\"cairn\",\"version\":\"0.1.0\"}}",
    )

  case state {
    Uninitialized -> #(Ready(session: s), Some(response), [meta])
    Ready(_) -> #(Ready(session: s), Some(response), [meta])
  }
}

fn meta_fragment(
  author: String,
  client_version: String,
  protocol_version: String,
) -> fragmentation.Fragment {
  // Timestamp from the MCP FFI clock isn't available here (no FFI in mcp.gleam).
  // Use "0" — the orchestrator timestamps are in the Witnessed fields of
  // session Fragments. The meta Fragment records structural provenance, not time.
  let w =
    fragmentation.witnessed(
      fragmentation.Author(author),
      fragmentation.Committer("cairn"),
      fragmentation.Timestamp("0"),
      fragmentation.Message("@meta"),
    )
  let data =
    "author: "
    <> author
    <> "\nclient_version: "
    <> client_version
    <> "\nprotocol_version: "
    <> protocol_version
  let r = fragmentation.ref(fragmentation.hash(data), "meta")
  fragmentation.shard(r, w, data)
}

fn handle_tool_call(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  case state {
    Uninitialized -> #(
      state,
      Some(make_error(id, -32_002, "not initialized")),
      [],
    )
    Ready(s) -> {
      let name = extract_nested(json, "params", "name")
      let args_str = extract_object(json, "params", "arguments")
      case json.decode(args_str) {
        Error(_) -> #(
          state,
          Some(make_response(id, content_text(err_json("invalid args json")))),
          [],
        )
        Ok(args) -> {
          let #(next_s, result_json, frags) = call_tool(s, name, args)
          #(
            Ready(session: next_s),
            Some(make_response(id, content_text(result_json))),
            frags,
          )
        }
      }
    }
  }
}

fn call_tool(
  s: session.Session,
  name: String,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  case name {
    "bias" -> tool_bias(s, args)
    "commit" -> tool_commit(s, args)
    _ -> #(s, err_json("unknown tool: " <> name), [])
  }
}

/// Bias tool: ODA with cascading constraint.
/// observation is always required.
/// action requires decision requires observation.
fn tool_bias(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  // Extract top-level annotation
  case json.get_string(args, "annotation") {
    Error(Nil) -> #(s, err_json("bias requires annotation"), [])
    Ok(annotation) -> {
      // Extract nested observation object
      let obs_str = extract_object_field(args, "observation")
      case json.decode(obs_str) {
        Error(_) -> #(s, err_json("bias requires observation"), [])
        Ok(obs_obj) -> {
          case
            json.get_string(obs_obj, "ref"),
            json.get_string(obs_obj, "payload")
          {
            Ok(obs_ref), Ok(obs_payload) ->
              build_bias(s, annotation, obs_ref, obs_payload, args)
            _, _ -> #(
              s,
              err_json("observation requires ref and payload"),
              [],
            )
          }
        }
      }
    }
  }
}

/// Build bias ADO bottom-up: act first, then decide wrapping acts,
/// then observe wrapping decisions. Collect all fragments.
fn build_bias(
  s: session.Session,
  annotation: String,
  obs_ref_str: String,
  obs_payload: String,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  // Check for action and decision
  let has_decision = has_object_field(args, "decision")
  let has_action = has_object_field(args, "action")

  // Cascading constraint: action requires decision
  case has_action && !has_decision {
    True -> #(s, err_json("action requires decision"), [])
    False -> {
      // Build bottom-up: act → decide → observe
      let #(s2, act_frags, act_shas) = case has_action {
        False -> #(s, [], [])
        True -> {
          let act_str = extract_object_field(args, "action")
          case json.decode(act_str) {
            Error(_) -> #(s, [], [])
            Ok(act_obj) -> {
              let act_annotation =
                result.unwrap(json.get_string(act_obj, "annotation"), annotation)
              let act_payload =
                result.unwrap(json.get_string(act_obj, "payload"), "")
              let #(s_a, act_ref) =
                session.act(s, act_annotation, act_payload)
              let sha = session.ref_sha(act_ref)
              let frags = session.fragments_for_ref(s_a, act_ref)
              #(s_a, frags, [sha])
            }
          }
        }
      }

      let #(s3, dec_frags, dec_shas) = case has_decision {
        False -> #(s2, [], [])
        True -> {
          let dec_str = extract_object_field(args, "decision")
          case json.decode(dec_str) {
            Error(_) -> #(s2, [], [])
            Ok(dec_obj) -> {
              let dec_annotation =
                result.unwrap(
                  json.get_string(dec_obj, "annotation"),
                  annotation,
                )
              let dec_payload =
                result.unwrap(json.get_string(dec_obj, "payload"), "")
              let obs_sha_ref = session.ObsRef(sha: session.head(s2))
              let #(s_d, dec_ref) =
                session.decide(
                  s2,
                  dec_annotation,
                  obs_sha_ref,
                  dec_payload,
                  act_frags,
                )
              let sha = session.ref_sha(dec_ref)
              let frags = session.fragments_for_ref(s_d, dec_ref)
              #(s_d, frags, [sha])
            }
          }
        }
      }

      // Always build observation
      let #(s4, obs_ref) =
        session.observe(s3, annotation, obs_ref_str, obs_payload, dec_frags)
      let obs_sha = session.ref_sha(obs_ref)
      let obs_frags = session.fragments_for_ref(s4, obs_ref)

      // Collect all fragments (act + decide + observe)
      let all_frags = list.flatten([act_frags, dec_frags, obs_frags])

      // Build response JSON with all SHAs
      let response = build_bias_response(obs_sha, dec_shas, act_shas)
      #(s4, response, all_frags)
    }
  }
}

fn build_bias_response(
  obs_sha: String,
  dec_shas: List(String),
  act_shas: List(String),
) -> String {
  let base = "{\"obs_sha\":\"" <> obs_sha <> "\""
  let with_dec = case dec_shas {
    [sha, ..] -> base <> ",\"dec_sha\":\"" <> sha <> "\""
    [] -> base
  }
  let with_act = case act_shas {
    [sha, ..] -> with_dec <> ",\"act_sha\":\"" <> sha <> "\""
    [] -> with_dec
  }
  with_act <> "}"
}

fn tool_commit(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  case json.get_string(args, "annotation") {
    Error(Nil) -> #(s, err_json("commit requires annotation"), [])
    Ok(annotation) -> {
      // MCP mode also requires a name
      let name = result.unwrap(json.get_string(args, "name"), "")
      case name {
        "" -> #(s, err_json("commit requires name"), [])
        _ -> {
          let obs_shas =
            result.unwrap(json.get_list(args, "observations"), [])
          let observations =
            shas_to_fragments(s, list.map(obs_shas, session.ObsRef))
          let #(s2, root, sha) =
            session.commit(s, annotation, observations)
          #(s2, "{\"root_sha\":\"" <> sha <> "\"}", [root])
        }
      }
    }
  }
}

fn shas_to_fragments(
  s: session.Session,
  refs: List(session.Ref),
) -> List(fragmentation.Fragment) {
  list.flat_map(refs, session.fragments_for_ref(s, _))
}

/// Extract a nested object field as a raw JSON string for re-parsing.
fn extract_object_field(obj: dynamic.Dynamic, field: String) -> String {
  let encoded = json.encode(obj)
  extract_object_from_json(encoded, field)
}

/// Check if a nested object field exists (non-empty).
fn has_object_field(obj: dynamic.Dynamic, field: String) -> Bool {
  let encoded = json.encode(obj)
  let val = extract_object_from_json(encoded, field)
  val != "{}" && val != ""
}

/// Extract a nested object from a JSON string by field name.
fn extract_object_from_json(json_str: String, field: String) -> String {
  let needle = "\"" <> field <> "\":"
  case string.split_once(json_str, needle) {
    Error(Nil) -> "{}"
    Ok(#(_, rest)) -> extract_json_value(string.trim_start(rest))
  }
}

fn err_json(msg: String) -> String {
  "{\"error\":\"" <> msg <> "\"}"
}

fn content_text(json_str: String) -> String {
  "{\"content\":[{\"type\":\"text\",\"text\":" <> json_str <> "}]}"
}

// ---------------------------------------------------------------------------
// JSON-RPC response builders (pure strings, no transport)
// ---------------------------------------------------------------------------

fn make_response(id: String, result: String) -> String {
  "{\"jsonrpc\":\"2.0\","
  <> "\"id\":"
  <> id
  <> ","
  <> "\"result\":"
  <> result
  <> "}"
}

fn make_error(id: String, code: Int, message: String) -> String {
  "{\"jsonrpc\":\"2.0\","
  <> "\"id\":"
  <> id
  <> ","
  <> "\"error\":{\"code\":"
  <> int.to_string(code)
  <> ",\"message\":\""
  <> message
  <> "\"}}"
}

// ---------------------------------------------------------------------------
// JSON helpers (pre-thoas, minimal string extraction)
// ---------------------------------------------------------------------------

/// Extract a top-level string field from a JSON object.
fn extract_field(json: String, field: String) -> String {
  let needle = "\"" <> field <> "\":"
  case string.split_once(json, needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_string_value(rest)
  }
}

/// Extract a nested string field: parent.child
fn extract_nested(json: String, parent: String, child: String) -> String {
  let parent_needle = "\"" <> parent <> "\":"
  case string.split_once(json, parent_needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_field(rest, child)
  }
}

/// Extract the raw JSON value of a nested object field.
/// Returns the raw JSON string for the value (for passing to thoas).
fn extract_object(json: String, parent: String, child: String) -> String {
  let parent_needle = "\"" <> parent <> "\":"
  case string.split_once(json, parent_needle) {
    Error(Nil) -> "{}"
    Ok(#(_, rest)) -> {
      let child_needle = "\"" <> child <> "\":"
      case string.split_once(rest, child_needle) {
        Error(Nil) -> "{}"
        Ok(#(_, after)) -> extract_json_value(string.trim_start(after))
      }
    }
  }
}

fn extract_string_value(s: String) -> String {
  case string.trim_start(s) {
    "\"" <> rest ->
      case string.split_once(rest, "\"") {
        Ok(#(value, _)) -> value
        Error(Nil) -> ""
      }
    _ -> ""
  }
}

fn extract_json_value(s: String) -> String {
  case s {
    "{" <> _ -> extract_balanced(s, "{", "}")
    "[" <> _ -> extract_balanced(s, "[", "]")
    "\"" <> _ -> "\"" <> extract_quoted(s)
    _ -> extract_primitive(s)
  }
}

fn extract_balanced(s: String, open: String, close: String) -> String {
  do_extract_balanced(s, open, close, 0, "")
}

fn do_extract_balanced(
  s: String,
  open: String,
  close: String,
  depth: Int,
  acc: String,
) -> String {
  case s {
    "" -> acc
    _ -> {
      let first = string.slice(s, 0, 1)
      let rest = string.drop_start(s, 1)
      let new_acc = acc <> first
      case first {
        c if c == open ->
          do_extract_balanced(rest, open, close, depth + 1, new_acc)
        c if c == close ->
          case depth - 1 {
            0 -> new_acc
            d -> do_extract_balanced(rest, open, close, d, new_acc)
          }
        _ -> do_extract_balanced(rest, open, close, depth, new_acc)
      }
    }
  }
}

fn extract_quoted(s: String) -> String {
  case string.drop_start(s, 1) {
    rest ->
      case string.split_once(rest, "\"") {
        Ok(#(value, _)) -> value <> "\""
        Error(Nil) -> ""
      }
  }
}

fn extract_primitive(s: String) -> String {
  case string.split_once(s, ",") {
    Ok(#(v, _)) -> string.trim(v)
    Error(Nil) ->
      case string.split_once(s, "}") {
        Ok(#(v, _)) -> string.trim(v)
        Error(Nil) -> string.trim(s)
      }
  }
}
// ---------------------------------------------------------------------------
// Tool definitions — imported from cairn/tools
// ---------------------------------------------------------------------------
// All tool schemas are defined in tools.gleam.
// MCP mode uses tools.mcp_tools_json() for the tools/list response.
