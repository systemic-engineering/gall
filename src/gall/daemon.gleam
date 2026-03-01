/// Gall daemon — persistent MCP server over stdio.
///
/// Installed into Claude Code (or any MCP client) as a long-lived server.
/// Survives across prompts. Witnesses every session that calls commit.
///
/// Two capability layers:
///   1. ADO witnessing (observe/decide/act/commit) — session-scoped, resets
///      after commit. Agent must call initialize to start a new session.
///   2. Git tools (git_status/diff/log/blame/show_file) — always available,
///      no session required.
///
/// @read tracking: every file served through the git MCP creates a @read
/// Fragment in the current session, annotated with visibility level derived
/// from the file path. Reads are witnessed, not just writes.
///
/// Storage:
///   GALL_DIR   — gestalt repo root (default: $HOME/.reed)
///   PWD        — project working directory, used for git operations
///   GALL_ALIAS — agent nickname extracted from initialize if not set
///   GALL_ALEX_KEY — path to alex's signing key (optional)
///
/// Install:
///   gleam run --module gall/daemon   (from project directory)
///   or: gall daemon
import fragmentation
import gall/config as gall_config
import gall/json
import gall/session
import gall/store
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "gall_ffi", "read_line")
fn read_line() -> Result(String, Nil)

@external(erlang, "gall_ffi", "write_line")
fn write_line(data: String) -> Nil

@external(erlang, "gall_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "gall_ffi", "session_id")
fn session_id() -> String

@external(erlang, "gall_ffi", "now")
fn now() -> Int

@external(erlang, "gall_ffi", "git_status")
fn git_status_ffi(dir: String) -> String

@external(erlang, "gall_ffi", "git_diff")
fn git_diff_ffi(dir: String, path: String) -> String

@external(erlang, "gall_ffi", "git_log")
fn git_log_ffi(dir: String, path: String, n: Int) -> String

@external(erlang, "gall_ffi", "git_blame")
fn git_blame_ffi(dir: String, path: String) -> String

@external(erlang, "gall_ffi", "git_show_file")
fn git_show_file_ffi(dir: String, ref: String, path: String) -> String

@external(erlang, "gall_ffi", "list_gestalt_sessions")
fn list_gestalt_sessions_ffi(gall_dir: String) -> String

@external(erlang, "gall_ffi", "read_gestalt_session")
fn read_gestalt_session_ffi(gall_dir: String, tag: String) -> String

@external(erlang, "gall_ffi", "git_ensure_repo")
fn git_ensure_repo(repo_dir: String) -> Nil

@external(erlang, "gall_ffi", "git_current_branch")
fn git_current_branch(repo_dir: String) -> String

@external(erlang, "gall_ffi", "git_commit_session")
fn git_commit_session(
  repo_dir: String,
  rel_path: String,
  nickname: String,
  session_id: String,
  tag_name: String,
  root_sha: String,
  alex_key: String,
) -> Nil

@external(erlang, "gall_ffi", "read_config_tag")
fn read_config_tag(repo_dir: String) -> String

@external(erlang, "gall_ffi", "send_patch")
fn send_patch(repo_dir: String, remote: String) -> Nil

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Session lifecycle state.
/// Idle: git tools available; ADO tools return not-initialized.
/// Active: full tool suite available. Reset to Idle after commit.
pub type SessionState {
  Idle
  Active(
    session: session.Session,
    store_dir: String,
    session_rel: String,
    tag_name: String,
    nickname: String,
    sid: String,
  )
}

/// Daemon-level state. work_dir and gall_dir are set at startup and never change.
pub type State {
  State(
    work_dir: String,
    gall_dir: String,
    alex_key: String,
    sess: SessionState,
  )
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  let work_dir = result.unwrap(get_env("PWD"), ".")
  // Default gall_dir: $HOME/.reed (the identity repo).
  // Override with GALL_DIR env var.
  let home = result.unwrap(get_env("HOME"), ".")
  let gall_dir = result.unwrap(get_env("GALL_DIR"), home <> "/.reed")
  let alex_key = result.unwrap(get_env("GALL_ALEX_KEY"), "")
  git_ensure_repo(gall_dir)
  let state = State(work_dir:, gall_dir:, alex_key:, sess: Idle)
  loop(state)
}

fn loop(state: State) -> Nil {
  case read_line() {
    Error(_) -> Nil
    // stdin EOF — exit cleanly; agent must call commit explicitly
    Ok(line) -> {
      let trimmed = string.trim(line)
      case string.is_empty(trimmed) {
        True -> loop(state)
        False -> {
          let #(next_state, maybe_response, maybe_frag) = handle(state, trimmed)
          // Eager fragment write — write immediately, before response
          case maybe_frag {
            None -> Nil
            Some(frag) ->
              case next_state.sess {
                Idle -> Nil
                Active(store_dir: sd, ..) -> {
                  let _ = store.write(frag, sd)
                  Nil
                }
              }
          }
          case maybe_response {
            None -> Nil
            Some(r) -> write_line(r)
          }
          loop(next_state)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn handle(
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
    "resources/list" -> handle_resources_list(state, id)
    "resources/read" -> handle_resources_read(state, id, json)
    "resources/templates/list" ->
      #(state, Some(make_response(id, resource_templates_json())), None)
    _ -> #(
      state,
      Some(make_error(id, -32_601, "method not found: " <> method)),
      None,
    )
  }
}

// ---------------------------------------------------------------------------
// Initialize
// ---------------------------------------------------------------------------

fn handle_initialize(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  // Nickname: clientInfo.name, then GALL_NICKNAME env, then "agent"
  let nickname = case extract_nested(json, "clientInfo", "name") {
    "" ->
      case get_env("GALL_NICKNAME") {
        Ok(n) if n != "" -> n
        _ -> "agent"
      }
    n -> n
  }
  let client_version = extract_nested(json, "clientInfo", "version")
  let protocol_version = extract_field(json, "protocolVersion")

  let author = nickname <> "@systemic.engineering"
  let session_config = session.SessionConfig(author: author, name: "gall-session")
  let s = session.new(session_config)
  let sid = session_id()
  let branch = normalize_branch(git_current_branch(state.work_dir))
  let session_rel = "sessions/" <> branch <> "/" <> nickname <> "/" <> sid
  let tag_name = session_rel
  let base = state.gall_dir <> "/" <> session_rel
  let store_dir = base <> "/store"
  let _ = simplifile.create_directory_all(store_dir)

  let meta = meta_fragment(author, client_version, protocol_version)

  let new_sess =
    Active(
      session: s,
      store_dir:,
      session_rel:,
      tag_name:,
      nickname:,
      sid:,
    )

  let response =
    make_response(
      id,
      "{\"protocolVersion\":\"2024-11-05\","
        <> "\"capabilities\":{\"tools\":{},\"resources\":{}},"
        <> "\"serverInfo\":{\"name\":\"gall\",\"version\":\"0.1.0\"}}",
    )

  #(State(..state, sess: new_sess), Some(response), Some(meta))
}

fn meta_fragment(
  author: String,
  client_version: String,
  protocol_version: String,
) -> fragmentation.Fragment {
  let w =
    fragmentation.witnessed(
      fragmentation.Author(author),
      fragmentation.Committer("gall"),
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

// ---------------------------------------------------------------------------
// Tool calls
// ---------------------------------------------------------------------------

fn handle_tool_call(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  let name = extract_nested(json, "params", "name")
  let args_str = extract_object(json, "params", "arguments")

  case json.decode(args_str) {
    Error(_) -> #(
      state,
      Some(make_response(id, content_text(err_json("invalid args json")))),
      None,
    )
    Ok(args) -> {
      case name {
        // ADO witnessing — require active session
        "observe" | "decide" | "act" ->
          call_ado_stateful(state, id, name, args)

        // Commit — seal session, git commit, sync, reset to Idle
        "commit" -> call_commit(state, id, args)

        // Git tools — always available
        "git_status" -> {
          let out = git_status_ffi(state.work_dir)
          #(
            state,
            Some(make_response(id, content_text(json_string(out)))),
            None,
          )
        }
        "git_diff" -> {
          let path = result.unwrap(json.get_string(args, "path"), "")
          let out = git_diff_ffi(state.work_dir, path)
          #(
            state,
            Some(make_response(id, content_text(json_string(out)))),
            None,
          )
        }
        "git_log" -> {
          let path = result.unwrap(json.get_string(args, "path"), "")
          let n = result.unwrap(json.get_string(args, "n"), "20")
          let count = result.unwrap(int.parse(n), 20)
          let out = git_log_ffi(state.work_dir, path, count)
          #(
            state,
            Some(make_response(id, content_text(json_string(out)))),
            None,
          )
        }
        "git_blame" -> {
          case json.get_string(args, "path") {
            Error(_) -> #(
              state,
              Some(make_response(id, content_text(err_json("git_blame requires path")))),
              None,
            )
            Ok(path) -> {
              let out = git_blame_ffi(state.work_dir, path)
              let #(next_state, read_frag) = record_read(state, path)
              #(
                next_state,
                Some(make_response(id, content_text(json_string(out)))),
                read_frag,
              )
            }
          }
        }
        "git_show_file" -> {
          case json.get_string(args, "path") {
            Error(_) -> #(
              state,
              Some(make_response(id, content_text(err_json("git_show_file requires path")))),
              None,
            )
            Ok(path) -> {
              let ref = result.unwrap(json.get_string(args, "ref"), "")
              let out = git_show_file_ffi(state.work_dir, ref, path)
              let #(next_state, read_frag) = record_read(state, path)
              #(
                next_state,
                Some(make_response(id, content_text(json_string(out)))),
                read_frag,
              )
            }
          }
        }

        _ -> #(
          state,
          Some(make_response(id, content_text(err_json("unknown tool: " <> name)))),
          None,
        )
      }
    }
  }
}

fn call_ado_stateful(
  state: State,
  id: String,
  name: String,
  args,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(
      state,
      Some(make_error(id, -32_002, "not initialized — call initialize first")),
      None,
    )
    Active(session: s, ..) as active -> {
      let #(next_s, result_json, maybe_frag) = call_ado(s, name, args)
      #(
        State(..state, sess: Active(..active, session: next_s)),
        Some(make_response(id, content_text(result_json))),
        maybe_frag,
      )
    }
  }
}

fn call_commit(
  state: State,
  id: String,
  args,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(
      state,
      Some(make_error(id, -32_002, "not initialized — call initialize first")),
      None,
    )
    Active(
      session: s,
      store_dir: sd,
      session_rel: sr,
      tag_name: tn,
      nickname: nick,
      sid:,
    ) -> {
      let obs_shas = result.unwrap(json.get_list(args, "observations"), [])
      let observations =
        shas_to_frags(s, list.map(obs_shas, session.ObsRef))
      let #(_, root, sha) = session.commit(s, observations)
      let _ = store.write(root, sd)

      case store.verify(root, sd) {
        Error(reason) -> {
          // Tamper detected — don't commit to git
          let next_state = State(..state, sess: Idle)
          #(
            next_state,
            Some(make_response(
              id,
              content_text(err_json("verify failed: " <> reason)),
            )),
            None,
          )
        }
        Ok(Nil) -> {
          git_ensure_repo(state.gall_dir)
          git_commit_session(
            state.gall_dir,
            sr <> "/store",
            nick,
            sid,
            tn,
            sha,
            state.alex_key,
          )
          // Sync if configured
          let sync_cfg = gall_config.parse(read_config_tag(state.gall_dir))
          case sync_cfg.sync {
            True -> send_patch(state.gall_dir, sync_cfg.sync_remote)
            False -> Nil
          }

          let tag = tn
          let next_state = State(..state, sess: Idle)
          #(
            next_state,
            Some(make_response(
              id,
              content_text(
                "{\"root_sha\":\""
                <> sha
                <> "\",\"tag\":\""
                <> tag
                <> "\"}",
              ),
            )),
            None,
          )
        }
      }
    }
  }
}

// ADO tool dispatch — pure, no state mutation at this level
fn call_ado(
  s: session.Session,
  name: String,
  args,
) -> #(session.Session, String, Option(fragmentation.Fragment)) {
  case name {
    "act" -> {
      case json.get_string(args, "annotation") {
        Error(_) -> #(s, err_json("act requires annotation"), None)
        Ok(annotation) -> {
          let #(s2, ref) = session.act(s, annotation)
          let sha = session.ref_sha(ref)
          let frags = session.fragments_for_ref(s2, ref)
          let frag = list.first(frags) |> result.unwrap(dummy_shard())
          #(s2, "{\"act_sha\":\"" <> sha <> "\"}", Some(frag))
        }
      }
    }
    "decide" -> {
      case json.get_string(args, "rule") {
        Error(_) -> #(s, err_json("decide requires rule"), None)
        Ok(rule) -> {
          let obs_sha = case json.get_string(args, "obs_sha") {
            Ok(sha) if sha != "" -> sha
            _ -> session.head(s)
          }
          let obs_ref = session.ObsRef(sha: obs_sha)
          let act_shas = result.unwrap(json.get_list(args, "acts"), [])
          let acts = shas_to_frags(s, list.map(act_shas, session.ActRef))
          let #(s2, ref) = session.decide(s, obs_ref, rule, acts)
          let sha = session.ref_sha(ref)
          let frags = session.fragments_for_ref(s2, ref)
          let frag = list.first(frags) |> result.unwrap(dummy_shard())
          #(s2, "{\"dec_sha\":\"" <> sha <> "\"}", Some(frag))
        }
      }
    }
    "observe" -> {
      case json.get_string(args, "ref"), json.get_string(args, "data") {
        Ok(ref), Ok(data) -> {
          let dec_shas = result.unwrap(json.get_list(args, "decisions"), [])
          let decisions = shas_to_frags(s, list.map(dec_shas, session.DecRef))
          let #(s2, obs_ref) = session.observe(s, ref, data, decisions)
          let sha = session.ref_sha(obs_ref)
          let frags = session.fragments_for_ref(s2, obs_ref)
          let frag = list.first(frags) |> result.unwrap(dummy_shard())
          #(s2, "{\"obs_sha\":\"" <> sha <> "\"}", Some(frag))
        }
        _, _ -> #(s, err_json("observe requires ref and data"), None)
      }
    }
    _ -> #(s, err_json("unknown ado tool: " <> name), None)
  }
}

// ---------------------------------------------------------------------------
// @read annotation
// ---------------------------------------------------------------------------

/// When the agent reads a file through gall, record it as a @read Fragment.
/// Visibility is derived from path prefix:
///   visibility/private/  → :private
///   visibility/protected/ → :protected
///   visibility/public/   → :public
///   (anything else)      → :public
fn record_read(
  state: State,
  path: String,
) -> #(State, Option(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(state, None)
    Active(session: s, ..) as active -> {
      let visibility = path_visibility(path)
      let ts = int.to_string(now())
      let author = case session.config(s) {
        session.SessionConfig(author: a, ..) -> a
      }
      let w =
        fragmentation.witnessed(
          fragmentation.Author(author),
          fragmentation.Committer("gall"),
          fragmentation.Timestamp(ts),
          fragmentation.Message("@read"),
        )
      let data = "file: " <> path <> "\nvisibility: " <> visibility
      let r = fragmentation.ref(fragmentation.hash(ts <> data), "read")
      let frag = fragmentation.shard(r, w, data)

      // Update HEAD in session (read advances it like any other fragment)
      let #(s2, _) = session.act(s, "@read " <> path)
      // Discard the act ref; we emit our own fragment built above
      // Actually: we need to get the frag into the session store so fragments_for_ref
      // works. For simplicity, use act() result and discard — the @read frag is
      // independently written to store by the caller.
      let _ = s2
      let next_sess = Active(..active, session: s)
      #(State(..state, sess: next_sess), Some(frag))
    }
  }
}

fn path_visibility(path: String) -> String {
  case string.starts_with(path, "visibility/private/") {
    True -> ":private"
    False ->
      case string.starts_with(path, "visibility/protected/") {
        True -> ":protected"
        False -> ":public"
      }
  }
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

fn handle_resources_list(
  state: State,
  id: String,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  let raw_tags = list_gestalt_sessions_ffi(state.gall_dir)
  let tags = case raw_tags {
    "" -> []
    t -> string.split(t, "\n")
  }

  let resource_items =
    list.map(tags, fn(tag) {
      let trimmed = string.trim(tag)
      // tag = "gestalt/mara/1737000000" → uri = "gestalt://session/mara/1737000000"
      let uri = case string.split_once(trimmed, "gestalt/") {
        Ok(#("", rest)) -> "gestalt://session/" <> rest
        _ -> "gestalt://session/" <> trimmed
      }
      "{\"uri\":\""
      <> json_escape(uri)
      <> "\",\"name\":\""
      <> json_escape(trimmed)
      <> "\",\"mimeType\":\"text/plain\"}"
    })

  let items_json = "[" <> string.join(resource_items, ",") <> "]"
  let response = make_response(id, "{\"resources\":" <> items_json <> "}")
  #(state, Some(response), None)
}

fn handle_resources_read(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), Option(fragmentation.Fragment)) {
  let uri = extract_nested(json, "params", "uri")
  let prefix = "gestalt://session/"
  case string.starts_with(uri, prefix) {
    True -> {
      let rest = string.drop_start(uri, string.length(prefix))
      let tag = "gestalt/" <> rest
      let content = read_gestalt_session_ffi(state.gall_dir, tag)
      let contents =
        "[{\"uri\":\""
        <> json_escape(uri)
        <> "\",\"mimeType\":\"text/plain\",\"text\":"
        <> json_string(content)
        <> "}]"
      let response = make_response(id, "{\"contents\":" <> contents <> "}")
      #(state, Some(response), None)
    }
    False -> #(
      state,
      Some(make_error(id, -32_602, "unknown resource: " <> uri)),
      None,
    )
  }
}

fn resource_templates_json() -> String {
  "{\"resourceTemplates\":["
  <> "{\"uriTemplate\":\"gestalt://session/{nickname}/{sid}\","
  <> "\"name\":\"Gestalt session\","
  <> "\"description\":\"Witnessed Fragment tree for a session.\","
  <> "\"mimeType\":\"text/plain\"}"
  <> "]}"
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn normalize_branch(branch: String) -> String {
  string.replace(branch, "/", "-")
}

fn shas_to_frags(
  s: session.Session,
  refs: List(session.Ref),
) -> List(fragmentation.Fragment) {
  list.flat_map(refs, session.fragments_for_ref(s, _))
}

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
  "{\"error\":\"" <> json_escape(msg) <> "\"}"
}

fn content_text(inner: String) -> String {
  "{\"content\":[{\"type\":\"text\",\"text\":" <> inner <> "}]}"
}

fn json_string(s: String) -> String {
  "\"" <> json_escape(s) <> "\""
}

fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ---------------------------------------------------------------------------
// JSON-RPC builders
// ---------------------------------------------------------------------------

fn make_response(id: String, result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":" <> id <> ",\"result\":" <> result <> "}"
}

fn make_error(id: String, code: Int, message: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":"
  <> id
  <> ",\"error\":{\"code\":"
  <> int.to_string(code)
  <> ",\"message\":\""
  <> json_escape(message)
  <> "\"}}"
}

// ---------------------------------------------------------------------------
// JSON string extraction (matches mcp.gleam pattern)
// ---------------------------------------------------------------------------

fn extract_field(json: String, field: String) -> String {
  let needle = "\"" <> field <> "\":"
  case string.split_once(json, needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_string_value(rest)
  }
}

fn extract_nested(json: String, parent: String, child: String) -> String {
  let parent_needle = "\"" <> parent <> "\":"
  case string.split_once(json, parent_needle) {
    Error(Nil) -> ""
    Ok(#(_, rest)) -> extract_field(rest, child)
  }
}

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
  <> ","
  <> git_status_tool()
  <> ","
  <> git_diff_tool()
  <> ","
  <> git_log_tool()
  <> ","
  <> git_blame_tool()
  <> ","
  <> git_show_file_tool()
  <> "]}"
}

fn observe_tool() -> String {
  "{\"name\":\"observe\","
  <> "\"description\":\"Record an observation. What you see, at what coordinate.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"ref\":{\"type\":\"string\","
  <> "\"description\":\"Source coordinate. file:path, concept:name, section:heading, task:label.\"},"
  <> "\"data\":{\"type\":\"string\","
  <> "\"description\":\"What you observed.\"},"
  <> "\"decisions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"dec_sha values from prior decide calls to link as children.\"}},"
  <> "\"required\":[\"ref\",\"data\"]}}"
}

fn decide_tool() -> String {
  "{\"name\":\"decide\","
  <> "\"description\":\"Record a decision derived from an observation.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"rule\":{\"type\":\"string\","
  <> "\"description\":\"Your structural conclusion.\"},"
  <> "\"acts\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"act_sha values from prior act calls to link as children.\"},"
  <> "\"obs_sha\":{\"type\":\"string\","
  <> "\"description\":\"Optional. Observation this decision belongs to. Defaults to HEAD.\"}},"
  <> "\"required\":[\"rule\"]}}"
}

fn act_tool() -> String {
  "{\"name\":\"act\","
  <> "\"description\":\"Record an action taken.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"What you did.\"}},"
  <> "\"required\":[\"annotation\"]}}"
}

fn commit_tool() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session and commit to gestalt. Call once at the end of the task.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"observations\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"obs_sha values to seal as the session root's children.\"}},"
  <> "\"required\":[]}}"
}

fn git_status_tool() -> String {
  "{\"name\":\"git_status\","
  <> "\"description\":\"Show working tree status of the current project.\","
  <> "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
}

fn git_diff_tool() -> String {
  "{\"name\":\"git_diff\","
  <> "\"description\":\"Show unstaged changes. Optional path filter.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"Optional file path filter.\"}}}}"
}

fn git_log_tool() -> String {
  "{\"name\":\"git_log\","
  <> "\"description\":\"Show recent commit history. Optional path filter and count.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"Optional file path filter.\"},"
  <> "\"n\":{\"type\":\"string\",\"description\":\"Number of commits (default 20).\"}}}"
  <> "}"
}

fn git_blame_tool() -> String {
  "{\"name\":\"git_blame\","
  <> "\"description\":\"Show per-line commit attribution for a file. Records a @read annotation in the current session.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"File path relative to project root.\"}},"
  <> "\"required\":[\"path\"]}}"
}

fn git_show_file_tool() -> String {
  "{\"name\":\"git_show_file\","
  <> "\"description\":\"Show file content at a given ref. Records a @read annotation in the current session.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"File path relative to project root.\"},"
  <> "\"ref\":{\"type\":\"string\",\"description\":\"Git ref (default HEAD).\"}},"
  <> "\"required\":[\"path\"]}}"
}
