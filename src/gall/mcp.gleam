/// Gall MCP protocol handler.
///
/// Transport-agnostic. Parses JSON-RPC, dispatches tools, returns:
///   - the next state
///   - the JSON response string to send (None = notification, no reply)
///   - the newly created Fragment (None = no Fragment this call)
///
/// The orchestrator (gall.gleam) owns the socket I/O and disk writes.
/// It calls handle/2 on each incoming message and acts on the outputs.
///
/// Protocol:
///   client → initialize(clientInfo.name = nickname)
///   server → capabilities + tool list
///   client → tools/call: observe | decide | act | commit
///   client exits → gall verifies store + commits session
///
/// The nickname from initialize becomes Author("<nickname>@systemic.engineering")
/// on every Fragment in the session. Identity is a protocol requirement.
import fragmentation
import gall/json
import gall/session
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
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  let method = extract_field(json, "method")
  let id = extract_field(json, "id")

  case method {
    "initialize" -> handle_initialize(state, id, json)
    "notifications/initialized" -> #(state, None, None)
    "tools/list" -> #(state, Some(make_response(id, tools_json())), None)
    "tools/call" -> handle_tool_call(state, id, json)
    _ -> #(
      state,
      Some(make_error(id, -32_601, "method not found: " <> method)),
      None,
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
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  let nickname = extract_nested(json, "clientInfo", "name")
  let author = nickname <> "@systemic.engineering"
  let config = session.SessionConfig(author: author, name: "gall-session")
  let s = session.new(config)

  let response =
    make_response(
      id,
      "{\"protocolVersion\":\"2024-11-05\","
        <> "\"capabilities\":{\"tools\":{}},"
        <> "\"serverInfo\":{\"name\":\"gall\",\"version\":\"0.1.0\"}}",
    )

  case state {
    Uninitialized -> #(Ready(session: s), Some(response), None)
    Ready(_) -> #(Ready(session: s), Some(response), None)
  }
}

fn handle_tool_call(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  case state {
    Uninitialized -> #(
      state,
      Some(make_error(id, -32_002, "not initialized")),
      None,
    )
    Ready(s) -> {
      let name = extract_nested(json, "params", "name")
      let args_str = extract_object(json, "params", "arguments")
      case json.decode(args_str) {
        Error(_) -> #(
          state,
          Some(
            make_response(
              id,
              content_text(err_json("invalid args json")),
            ),
          ),
          None,
        )
        Ok(args) -> {
          let #(next_s, result_json, maybe_frag) = call_tool(s, name, args)
          #(
            Ready(session: next_s),
            Some(make_response(id, content_text(result_json))),
            maybe_frag,
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
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case name {
    "act" -> tool_act(s, args)
    "decide" -> tool_decide(s, args)
    "observe" -> tool_observe(s, args)
    "commit" -> tool_commit(s, args)
    _ -> #(s, err_json("unknown tool: " <> name), None)
  }
}

fn tool_act(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case json.get_string(args, "annotation") {
    Error(Nil) -> #(s, err_json("act requires annotation"), None)
    Ok(annotation) -> {
      let #(s2, ref) = session.act(s, annotation)
      let sha = session.ref_sha(ref)
      let frags = session.fragments_for_ref(s2, ref)
      let frag = list.first(frags) |> result.unwrap(dummy_shard())
      #(s2, "{\"act_sha\":\"" <> sha <> "\"}", Some(frag))
    }
  }
}

fn tool_decide(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case json.get_string(args, "rule") {
    Error(Nil) -> #(s, err_json("decide requires rule"), None)
    Ok(rule) -> {
      let obs_sha = result.unwrap(json.get_string(args, "obs_sha"), "")
      let obs_ref = session.ObsRef(sha: obs_sha)
      let act_shas = result.unwrap(json.get_list(args, "acts"), [])
      let acts = shas_to_fragments(s, list.map(act_shas, session.ActRef))
      let #(s2, ref) = session.decide(s, obs_ref, rule, acts)
      let sha = session.ref_sha(ref)
      let frags = session.fragments_for_ref(s2, ref)
      let frag = list.first(frags) |> result.unwrap(dummy_shard())
      #(s2, "{\"dec_sha\":\"" <> sha <> "\"}", Some(frag))
    }
  }
}

fn tool_observe(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case json.get_string(args, "ref"), json.get_string(args, "data") {
    Ok(ref), Ok(data) -> {
      let dec_shas = result.unwrap(json.get_list(args, "decisions"), [])
      let decisions = shas_to_fragments(s, list.map(dec_shas, session.DecRef))
      let #(s2, obs_ref) = session.observe(s, ref, data, decisions)
      let sha = session.ref_sha(obs_ref)
      let frags = session.fragments_for_ref(s2, obs_ref)
      let frag = list.first(frags) |> result.unwrap(dummy_shard())
      #(s2, "{\"obs_sha\":\"" <> sha <> "\"}", Some(frag))
    }
    _, _ -> #(s, err_json("observe requires ref and data"), None)
  }
}

fn tool_commit(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case json.get_string(args, "name") {
    Error(Nil) -> #(s, err_json("commit requires name"), None)
    Ok(_name) -> {
      let obs_shas = result.unwrap(json.get_list(args, "observations"), [])
      let observations =
        shas_to_fragments(s, list.map(obs_shas, session.ObsRef))
      let #(s2, root, sha) = session.commit(s, observations)
      #(s2, "{\"root_sha\":\"" <> sha <> "\"}", Some(root))
    }
  }
}

fn shas_to_fragments(
  s: session.Session,
  refs: List(session.Ref),
) -> List(fragmentation.Fragment) {
  list.flat_map(refs, session.fragments_for_ref(s, _))
}

// Fallback for when a tool's fragment lookup fails.
// Should never happen in practice — acts, decides, observes always store.
fn dummy_shard() -> fragmentation.Fragment {
  let r = fragmentation.ref(fragmentation.hash("dummy"), "dummy")
  let w =
    fragmentation.witnessed(
      fragmentation.Author("gall"),
      fragmentation.Committer("gall"),
      fragmentation.Timestamp("0"),
      fragmentation.Message("dummy"),
    )
  fragmentation.shard(r, w, "dummy")
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
        c if c == open -> do_extract_balanced(rest, open, close, depth + 1, new_acc)
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
// Tool definitions
// ---------------------------------------------------------------------------

fn tools_json() -> String {
  "{\"tools\":["
  <> observe_tool()
  <> ","
  <> decide_tool()
  <> ","
  <> act_tool()
  <> ","
  <> commit_tool()
  <> "]}"
}

fn observe_tool() -> String {
  "{\"name\":\"observe\","
  <> "\"description\":\"Record an observation. What you see, at what coordinate.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"ref\":{\"type\":\"string\","
  <> "\"description\":\"Source coordinate. Use file:path, concept:name, section:heading, or task:label.\"},"
  <> "\"data\":{\"type\":\"string\","
  <> "\"description\":\"What you observed.\"}},"
  <> "\"required\":[\"ref\",\"data\"]}}"
}

fn decide_tool() -> String {
  "{\"name\":\"decide\","
  <> "\"description\":\"Record a decision derived from an observation.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"obs_sha\":{\"type\":\"string\","
  <> "\"description\":\"The obs_sha returned by observe.\"},"
  <> "\"rule\":{\"type\":\"string\","
  <> "\"description\":\"Your structural conclusion.\"}},"
  <> "\"required\":[\"obs_sha\",\"rule\"]}}"
}

fn act_tool() -> String {
  "{\"name\":\"act\","
  <> "\"description\":\"Record an action taken as a result of a decision.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"dec_sha\":{\"type\":\"string\","
  <> "\"description\":\"The dec_sha returned by decide.\"},"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"What you did.\"}},"
  <> "\"required\":[\"dec_sha\",\"annotation\"]}}"
}

fn commit_tool() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session. Call once at the end of the task.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"name\":{\"type\":\"string\","
  <> "\"description\":\"Session name.\"}},"
  <> "\"required\":[\"name\"]}}"
}
