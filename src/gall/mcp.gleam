/// Gall MCP server.
///
/// Stdio JSON-RPC 2.0. Newline-framed.
///
/// Protocol:
///   client → initialize(clientInfo.name = nickname)
///   server → capabilities + tool list
///   client → tools/call: observe | decide | act | commit
///   client exits → gall commits session to .mara/gestalt
///
/// The nickname from initialize becomes Author("<nickname>@systemic.engineering")
/// on every Fragment in the session. Identity is a protocol requirement.
import fragmentation
import gall/json
import gall/session
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/result
import gleam/string

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "gall_ffi", "read_line")
fn read_line() -> Result(String, Nil)

@external(erlang, "gall_ffi", "write_line")
fn write_line(line: String) -> Nil

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  loop(Uninitialized)
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

type State {
  Uninitialized
  Ready(session: session.Session)
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------

fn loop(state: State) -> Nil {
  case read_line() {
    Error(Nil) -> on_exit(state)
    Ok(line) ->
      case string.trim(line) {
        "" -> loop(state)
        json -> {
          let next = dispatch(state, json)
          loop(next)
        }
      }
  }
}

fn on_exit(state: State) -> Nil {
  case state {
    Uninitialized -> Nil
    Ready(_session) ->
      // TODO: commit session to .mara/gestalt with exit code
      Nil
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn dispatch(state: State, json: String) -> State {
  // Minimal JSON field extraction via string matching.
  // Replaced with thoas once deps download completes.
  let method = extract_field(json, "method")
  let id = extract_field(json, "id")

  case method {
    "initialize" -> handle_initialize(state, id, json)
    "notifications/initialized" -> state
    "tools/list" -> {
      handle_tools_list(id)
      state
    }
    "tools/call" -> handle_tool_call(state, id, json)
    _ -> {
      write_error(id, -32_601, "method not found: " <> method)
      state
    }
  }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handle_initialize(state: State, id: String, json: String) -> State {
  let nickname = extract_nested(json, "clientInfo", "name")
  let author = nickname <> "@systemic.engineering"
  let config = session.SessionConfig(author: author, name: "gall-session")
  let s = session.new(config)

  write_response(
    id,
    "{\"protocolVersion\":\"2024-11-05\","
      <> "\"capabilities\":{\"tools\":{}},"
      <> "\"serverInfo\":{\"name\":\"gall\",\"version\":\"0.1.0\"}}",
  )

  case state {
    Uninitialized -> Ready(session: s)
    Ready(_) -> Ready(session: s)
  }
}

fn handle_tools_list(id: String) -> Nil {
  write_response(id, tools_json())
}

fn handle_tool_call(state: State, id: String, json: String) -> State {
  case state {
    Uninitialized -> {
      write_error(id, -32_002, "not initialized")
      state
    }
    Ready(s) -> {
      let name = extract_nested(json, "params", "name")
      let args = extract_nested(json, "params", "arguments")
      let #(next_s, result_json) = call_tool(s, name, args)
      write_response(
        id,
        "{\"content\":[{\"type\":\"text\",\"text\":" <> result_json <> "}]}",
      )
      Ready(session: next_s)
    }
  }
}

fn call_tool(
  s: session.Session,
  name: String,
  args_str: String,
) -> #(session.Session, String) {
  case json.decode(args_str) {
    Error(_) -> #(s, err_json("invalid args json"))
    Ok(args) ->
      case name {
        "act" -> tool_act(s, args)
        "decide" -> tool_decide(s, args)
        "observe" -> tool_observe(s, args)
        "commit" -> tool_commit(s, args)
        _ -> #(s, err_json("unknown tool: " <> name))
      }
  }
}

fn tool_act(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String) {
  case json.get_string(args, "annotation") {
    Error(Nil) -> #(s, err_json("act requires annotation"))
    Ok(annotation) -> {
      let #(s2, ref) = session.act(s, annotation)
      let sha = session.ref_sha(ref)
      #(s2, "{\"act_sha\":\"" <> sha <> "\"}")
    }
  }
}

fn tool_decide(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String) {
  case json.get_string(args, "rule") {
    Error(Nil) -> #(s, err_json("decide requires rule"))
    Ok(rule) -> {
      let obs_sha = result.unwrap(json.get_string(args, "obs_sha"), "")
      let obs_ref = session.ObsRef(sha: obs_sha)
      let act_shas = result.unwrap(json.get_list(args, "acts"), [])
      let acts = shas_to_fragments(s, list.map(act_shas, session.ActRef))
      let #(s2, ref) = session.decide(s, obs_ref, rule, acts)
      let sha = session.ref_sha(ref)
      #(s2, "{\"dec_sha\":\"" <> sha <> "\"}")
    }
  }
}

fn tool_observe(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String) {
  case json.get_string(args, "ref"), json.get_string(args, "data") {
    Ok(ref), Ok(data) -> {
      let dec_shas = result.unwrap(json.get_list(args, "decisions"), [])
      let decisions = shas_to_fragments(s, list.map(dec_shas, session.DecRef))
      let #(s2, obs_ref) = session.observe(s, ref, data, decisions)
      let sha = session.ref_sha(obs_ref)
      #(s2, "{\"obs_sha\":\"" <> sha <> "\"}")
    }
    _, _ -> #(s, err_json("observe requires ref and data"))
  }
}

fn tool_commit(
  s: session.Session,
  args: dynamic.Dynamic,
) -> #(session.Session, String) {
  case json.get_string(args, "name") {
    Error(Nil) -> #(s, err_json("commit requires name"))
    Ok(name) -> {
      let obs_shas = result.unwrap(json.get_list(args, "observations"), [])
      let observations =
        shas_to_fragments(s, list.map(obs_shas, session.ObsRef))
      let #(s2, _root, sha) = session.commit(s, observations)
      #(s2, "{\"root_sha\":\"" <> sha <> "\"}")
    }
  }
}

fn shas_to_fragments(
  s: session.Session,
  refs: List(session.Ref),
) -> List(fragmentation.Fragment) {
  list.flat_map(refs, session.fragments_for_ref(s, _))
}

fn err_json(msg: String) -> String {
  "{\"error\":\"" <> msg <> "\"}"
}

// ---------------------------------------------------------------------------
// JSON helpers (pre-thoas, minimal string extraction)
// ---------------------------------------------------------------------------

/// Extract a top-level string field from a JSON object.
/// "method":"initialize" → "initialize"
fn extract_field(json: String, field: String) -> String {
  let needle = "\"" <> field <> "\":"
  case string.split_once(json, needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_string_value(rest)
  }
}

/// Extract a nested field: params.name
fn extract_nested(json: String, parent: String, child: String) -> String {
  let parent_needle = "\"" <> parent <> "\":"
  case string.split_once(json, parent_needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_field(rest, child)
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

// ---------------------------------------------------------------------------
// JSON-RPC response writers
// ---------------------------------------------------------------------------

fn write_response(id: String, result: String) -> Nil {
  let msg =
    "{\"jsonrpc\":\"2.0\","
    <> "\"id\":"
    <> id
    <> ","
    <> "\"result\":"
    <> result
    <> "}"
  write_line(msg)
}

fn write_error(id: String, code: Int, message: String) -> Nil {
  let msg =
    "{\"jsonrpc\":\"2.0\","
    <> "\"id\":"
    <> id
    <> ","
    <> "\"error\":{\"code\":"
    <> int.to_string(code)
    <> ",\"message\":\""
    <> message
    <> "\"}}"
  write_line(msg)
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
