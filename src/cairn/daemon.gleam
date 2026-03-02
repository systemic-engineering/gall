/// Cairn daemon — persistent MCP server over stdio.
///
/// Installed into Claude Code (or any MCP client) as a long-lived server.
/// Survives across prompts. Witnesses every session that calls commit.
///
/// Two capability layers:
///   1. Bias witnessing (bias/commit) — session-scoped, resets after commit.
///      Agent must call initialize to start a new session.
///   2. Git tools (git_status/diff/log/blame/show_file) — always available,
///      no session required.
///
/// @read tracking: every file served through the git MCP creates a @read
/// Fragment in the current session, annotated with visibility level derived
/// from the file path. Reads are witnessed, not just writes.
///
/// Storage:
///   CAIRN_WORKTREE — project working directory (overrides PWD; set by cairn spawn)
///   CAIRN_BRANCH   — branch name (overrides git rev-parse; set by cairn spawn)
///   CAIRN_ALEX_KEY — path to alex's signing key (optional)
///
/// .cairn/ lives inside the project. No nested git repo.
/// The project's own git tracks .cairn/sessions/... as plain files.
/// Session tags (sessions/<branch>/<name>/<timestamp>) live in the project git.
///
/// Install:
///   gleam run --module cairn/daemon   (from project directory)
///   or: cairn daemon
import fragmentation
import cairn/config as cairn_config
import cairn/json
import cairn/session
import cairn/store
import cairn/tools
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "cairn_ffi", "read_line")
fn read_line() -> Result(String, Nil)

@external(erlang, "cairn_ffi", "write_line")
fn write_line(data: String) -> Nil

@external(erlang, "cairn_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "cairn_ffi", "session_id")
fn session_id() -> String

@external(erlang, "cairn_ffi", "now")
fn now() -> Int

@external(erlang, "cairn_ffi", "git_status")
fn git_status_ffi(dir: String) -> String

@external(erlang, "cairn_ffi", "git_diff")
fn git_diff_ffi(dir: String, path: String) -> String

@external(erlang, "cairn_ffi", "git_log")
fn git_log_ffi(dir: String, path: String, n: Int) -> String

@external(erlang, "cairn_ffi", "git_blame")
fn git_blame_ffi(dir: String, path: String) -> String

@external(erlang, "cairn_ffi", "git_show_file")
fn git_show_file_ffi(dir: String, ref: String, path: String) -> String

@external(erlang, "cairn_ffi", "exec")
fn exec_ffi(dir: String, command: String) -> String

@external(erlang, "cairn_ffi", "list_gestalt_sessions")
fn list_gestalt_sessions_ffi(cairn_dir: String) -> String

@external(erlang, "cairn_ffi", "read_gestalt_session")
fn read_gestalt_session_ffi(cairn_dir: String, tag: String) -> String

@external(erlang, "cairn_ffi", "git_current_branch")
fn git_current_branch(repo_dir: String) -> String

@external(erlang, "cairn_ffi", "git_commit_session")
fn git_commit_session(
  repo_dir: String,
  rel_path: String,
  nickname: String,
  session_id: String,
  tag_name: String,
  root_sha: String,
  alex_key: String,
) -> Nil

@external(erlang, "cairn_ffi", "read_config_tag")
fn read_config_tag(repo_dir: String) -> String

@external(erlang, "cairn_ffi", "send_patch")
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

/// Daemon-level state. work_dir and branch are set at startup and never change.
/// cairn_dir = work_dir <> "/.cairn" — derived, not stored separately.
/// branch = CAIRN_BRANCH env (if set) else git_current_branch — already normalized.
pub type State {
  State(work_dir: String, branch: String, alex_key: String, sess: SessionState)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  // CAIRN_WORKTREE overrides PWD — set when cairn spawns an agent into a worktree.
  let work_dir =
    result.unwrap(get_env("CAIRN_WORKTREE"), result.unwrap(get_env("PWD"), "."))
  // CAIRN_BRANCH overrides git rev-parse — reliable in detached-worktree contexts.
  let branch = case get_env("CAIRN_BRANCH") {
    Ok(b) if b != "" -> normalize_branch(b)
    _ -> normalize_branch(git_current_branch(work_dir))
  }
  let alex_key = result.unwrap(get_env("CAIRN_ALEX_KEY"), "")
  let cairn_dir = work_dir <> "/.cairn"
  let _ = simplifile.create_directory_all(cairn_dir)
  let state = State(work_dir:, branch:, alex_key:, sess: Idle)
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
          let #(next_state, maybe_response, frags) = handle(state, trimmed)
          // Eager fragment write — write immediately, before response
          case next_state.sess {
            Idle -> Nil
            Active(store_dir: sd, ..) ->
              list.each(frags, fn(frag) {
                let _ = store.write(frag, sd)
                Nil
              })
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
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let method = extract_field(json, "method")
  let id = extract_raw_field(json, "id")

  case method {
    "initialize" -> handle_initialize(state, id, json)
    "notifications/initialized" -> #(state, None, [])
    "tools/list" -> #(
      state,
      Some(make_response(id, tools.daemon_tools_json())),
      [],
    )
    "tools/call" -> handle_tool_call(state, id, json)
    "resources/list" -> handle_resources_list(state, id)
    "resources/read" -> handle_resources_read(state, id, json)
    "resources/templates/list" -> #(
      state,
      Some(make_response(id, resource_templates_json())),
      [],
    )
    _ -> #(
      state,
      Some(make_error(id, -32_601, "method not found: " <> method)),
      [],
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
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  // Nickname: clientInfo.name, then CAIRN_NICKNAME env, then "agent"
  let nickname = case extract_nested(json, "clientInfo", "name") {
    "" ->
      case get_env("CAIRN_NICKNAME") {
        Ok(n) if n != "" -> n
        _ -> "agent"
      }
    n -> n
  }
  let client_version = extract_nested(json, "clientInfo", "version")
  let protocol_version = extract_field(json, "protocolVersion")

  let author = nickname <> "@systemic.engineering"
  let session_config =
    session.SessionConfig(author: author, name: "cairn-session")
  let s = session.new(session_config)
  let sid = session_id()
  let session_rel =
    "actors/" <> nickname <> "/worktrees/" <> state.branch <> "/" <> sid
  let tag_name = "cairn/" <> state.branch <> "/" <> nickname <> "/" <> sid
  let base = state.work_dir <> "/.cairn/" <> session_rel
  let store_dir = base <> "/store"
  let _ = simplifile.create_directory_all(store_dir)

  let meta = meta_fragment(author, client_version, protocol_version)

  let new_sess =
    Active(session: s, store_dir:, session_rel:, tag_name:, nickname:, sid:)

  let response =
    make_response(
      id,
      "{\"protocolVersion\":\"2024-11-05\","
        <> "\"capabilities\":{\"tools\":{},\"resources\":{}},"
        <> "\"serverInfo\":{\"name\":\"cairn\",\"version\":\"0.1.0\"}}",
    )

  #(State(..state, sess: new_sess), Some(response), [meta])
}

fn meta_fragment(
  author: String,
  client_version: String,
  protocol_version: String,
) -> fragmentation.Fragment {
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

// ---------------------------------------------------------------------------
// Tool calls
// ---------------------------------------------------------------------------

fn handle_tool_call(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let name = extract_nested(json, "params", "name")
  let args_str = extract_object(json, "params", "arguments")

  case json.decode(args_str) {
    Error(_) -> #(
      state,
      Some(make_response(id, content_text(err_json("invalid args json")))),
      [],
    )
    Ok(args) -> {
      case name {
        // Bias witnessing — require active session
        "bias" -> call_bias_stateful(state, id, args)

        // Commit — seal session, git commit, sync, reset to Idle
        "commit" -> call_commit(state, id, args)

        // Git tools — always available
        "git_status" -> {
          let out = git_status_ffi(state.work_dir)
          #(
            state,
            Some(make_response(id, content_text(json_string(out)))),
            [],
          )
        }
        "git_diff" -> {
          let path = result.unwrap(json.get_string(args, "path"), "")
          let out = git_diff_ffi(state.work_dir, path)
          #(
            state,
            Some(make_response(id, content_text(json_string(out)))),
            [],
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
            [],
          )
        }
        "git_blame" -> {
          case json.get_string(args, "path") {
            Error(_) -> #(
              state,
              Some(make_response(
                id,
                content_text(err_json("git_blame requires path")),
              )),
              [],
            )
            Ok(path) -> {
              let out = git_blame_ffi(state.work_dir, path)
              let #(next_state, read_frags) = record_read(state, path)
              #(
                next_state,
                Some(make_response(id, content_text(json_string(out)))),
                read_frags,
              )
            }
          }
        }
        "git_show_file" -> {
          case json.get_string(args, "path") {
            Error(_) -> #(
              state,
              Some(make_response(
                id,
                content_text(err_json("git_show_file requires path")),
              )),
              [],
            )
            Ok(path) -> {
              let ref = result.unwrap(json.get_string(args, "ref"), "")
              let out = git_show_file_ffi(state.work_dir, ref, path)
              let #(next_state, read_frags) = record_read(state, path)
              #(
                next_state,
                Some(make_response(id, content_text(json_string(out)))),
                read_frags,
              )
            }
          }
        }

        _ -> #(
          state,
          Some(make_response(
            id,
            content_text(err_json("unknown tool: " <> name)),
          )),
          [],
        )
      }
    }
  }
}

fn call_bias_stateful(
  state: State,
  id: String,
  args: dynamic.Dynamic,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(
      state,
      Some(make_error(id, -32_002, "not initialized — call initialize first")),
      [],
    )
    Active(session: s, ..) as active -> {
      let #(next_s, result_json, frags) =
        call_bias(s, state.work_dir, args)
      #(
        State(..state, sess: Active(..active, session: next_s)),
        Some(make_response(id, content_text(result_json))),
        frags,
      )
    }
  }
}

fn call_commit(
  state: State,
  id: String,
  args,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(
      state,
      Some(make_error(id, -32_002, "not initialized — call initialize first")),
      [],
    )
    Active(
      session: s,
      store_dir: sd,
      session_rel: sr,
      tag_name: tn,
      nickname: nick,
      sid:,
    ) -> {
      let annotation =
        result.unwrap(json.get_string(args, "annotation"), "commit")
      let obs_shas = result.unwrap(json.get_list(args, "observations"), [])
      let observations = shas_to_frags(s, list.map(obs_shas, session.ObsRef))
      let #(_, root, sha) = session.commit(s, annotation, observations)
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
            [],
          )
        }
        Ok(Nil) -> {
          // Commit .cairn/sessions/... into the project's git (no nested repo).
          git_commit_session(
            state.work_dir,
            ".cairn/" <> sr <> "/store",
            nick,
            sid,
            tn,
            sha,
            state.alex_key,
          )
          // Sync if configured
          let sync_cfg = cairn_config.parse(read_config_tag(state.work_dir))
          case sync_cfg.sync {
            True -> send_patch(state.work_dir, sync_cfg.sync_remote)
            False -> Nil
          }

          let tag = tn
          let next_state = State(..state, sess: Idle)
          #(
            next_state,
            Some(make_response(
              id,
              content_text(
                "{\"root_sha\":\"" <> sha <> "\",\"tag\":\"" <> tag <> "\"}",
              ),
            )),
            [],
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Bias tool — ODA with cascading constraint + @exec effecting
// ---------------------------------------------------------------------------

/// Bias tool: ODA with cascading constraint.
/// observation is always required.
/// action requires decision requires observation.
/// When action.annotation is "@exec", run the command via exec_ffi.
fn call_bias(
  s: session.Session,
  work_dir: String,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  case json.get_string(args, "annotation") {
    Error(Nil) -> #(s, err_json("bias requires annotation"), [])
    Ok(annotation) -> {
      let obs_str = extract_object_field(args, "observation")
      case json.decode(obs_str) {
        Error(_) -> #(s, err_json("bias requires observation"), [])
        Ok(obs_obj) -> {
          case
            json.get_string(obs_obj, "ref"),
            json.get_string(obs_obj, "payload")
          {
            Ok(obs_ref), Ok(obs_payload) ->
              build_bias(s, work_dir, annotation, obs_ref, obs_payload, args)
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
/// For @exec actions, run the command and include output in response.
fn build_bias(
  s: session.Session,
  work_dir: String,
  annotation: String,
  obs_ref_str: String,
  obs_payload: String,
  args: dynamic.Dynamic,
) -> #(session.Session, String, List(fragmentation.Fragment)) {
  let has_decision = has_object_field(args, "decision")
  let has_action = has_object_field(args, "action")

  // Cascading constraint: action requires decision
  case has_action && !has_decision {
    True -> #(s, err_json("action requires decision"), [])
    False -> {
      // Build bottom-up: act → decide → observe
      let #(s2, act_frags, act_shas, exec_output) = case has_action {
        False -> #(s, [], [], None)
        True -> {
          let act_str = extract_object_field(args, "action")
          case json.decode(act_str) {
            Error(_) -> #(s, [], [], None)
            Ok(act_obj) -> {
              let act_annotation =
                result.unwrap(json.get_string(act_obj, "annotation"), annotation)
              let act_payload =
                result.unwrap(json.get_string(act_obj, "payload"), "")
              // @exec: run the command, record output
              let exec_out = case act_annotation {
                "@exec" -> Some(exec_ffi(work_dir, act_payload))
                _ -> None
              }
              let #(s_a, act_ref) =
                session.act(s, act_annotation, act_payload)
              let sha = session.ref_sha(act_ref)
              let frags = session.fragments_for_ref(s_a, act_ref)
              #(s_a, frags, [sha], exec_out)
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

      // Build response JSON with all SHAs + exec output if present
      let response =
        build_bias_response(obs_sha, dec_shas, act_shas, exec_output)
      #(s4, response, all_frags)
    }
  }
}

fn build_bias_response(
  obs_sha: String,
  dec_shas: List(String),
  act_shas: List(String),
  exec_output: Option(String),
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
  let with_exec = case exec_output {
    Some(out) -> with_act <> ",\"exec_output\":" <> json_string(out)
    None -> with_act
  }
  with_exec <> "}"
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

// ---------------------------------------------------------------------------
// @read annotation
// ---------------------------------------------------------------------------

/// When the agent reads a file through cairn, record it as a @read Fragment.
/// Visibility is derived from path prefix:
///   visibility/private/  → :private
///   visibility/protected/ → :protected
///   visibility/public/   → :public
///   (anything else)      → :public
fn record_read(
  state: State,
  path: String,
) -> #(State, List(fragmentation.Fragment)) {
  case state.sess {
    Idle -> #(state, [])
    Active(session: s, ..) as active -> {
      let visibility = path_visibility(path)
      let ts = int.to_string(now())
      let author = case session.config(s) {
        session.SessionConfig(author: a, ..) -> a
      }
      let w =
        fragmentation.witnessed(
          fragmentation.Author(author),
          fragmentation.Committer("cairn"),
          fragmentation.Timestamp(ts),
          fragmentation.Message("@read"),
        )
      let data = "file: " <> path <> "\nvisibility: " <> visibility
      let r = fragmentation.ref(fragmentation.hash(ts <> data), "read")
      let frag = fragmentation.shard(r, w, data)

      // Update HEAD in session (read advances it like any other fragment)
      let #(s2, _) = session.act(s, "@read", "file: " <> path)
      // Use the updated session so HEAD advances on reads.
      // The @read fragment is independently written to store by the caller.
      let next_sess = Active(..active, session: s2)
      #(State(..state, sess: next_sess), [frag])
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
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let raw_tags = list_gestalt_sessions_ffi(state.work_dir)
  let tags = case raw_tags {
    "" -> []
    t -> string.split(t, "\n")
  }

  let resource_items =
    list.map(tags, fn(tag) {
      let trimmed = string.trim(tag)
      // tag = "cairn/main/mara/1737000000" → uri = "cairn://main/mara/1737000000"
      let uri = case string.split_once(trimmed, "cairn/") {
        Ok(#("", rest)) -> "cairn://" <> rest
        _ -> "cairn://" <> trimmed
      }
      "{\"uri\":\""
      <> json_escape(uri)
      <> "\",\"name\":\""
      <> json_escape(trimmed)
      <> "\",\"mimeType\":\"text/plain\"}"
    })

  let items_json = "[" <> string.join(resource_items, ",") <> "]"
  let response = make_response(id, "{\"resources\":" <> items_json <> "}")
  #(state, Some(response), [])
}

fn handle_resources_read(
  state: State,
  id: String,
  json: String,
) -> #(State, Option(String), List(fragmentation.Fragment)) {
  let uri = extract_nested(json, "params", "uri")
  let prefix = "cairn://"
  case string.starts_with(uri, prefix) {
    True -> {
      let rest = string.drop_start(uri, string.length(prefix))
      let tag = "cairn/" <> rest
      let content = read_gestalt_session_ffi(state.work_dir, tag)
      let contents =
        "[{\"uri\":\""
        <> json_escape(uri)
        <> "\",\"mimeType\":\"text/plain\",\"text\":"
        <> json_string(content)
        <> "}]"
      let response = make_response(id, "{\"contents\":" <> contents <> "}")
      #(state, Some(response), [])
    }
    False -> #(
      state,
      Some(make_error(id, -32_602, "unknown resource: " <> uri)),
      [],
    )
  }
}

fn resource_templates_json() -> String {
  "{\"resourceTemplates\":["
  <> "{\"uriTemplate\":\"cairn://{branch}/{actor}/{ts}\","
  <> "\"name\":\"Session\","
  <> "\"description\":\"Witnessed Fragment record. cairn://<branch>/<actor>/<ts>\","
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

/// Extract a raw JSON value (number, string, object, etc.) for a field.
/// Used for "id" which can be a number or string in JSON-RPC.
fn extract_raw_field(json: String, field: String) -> String {
  let needle = "\"" <> field <> "\":"
  case string.split_once(json, needle) {
    Error(Nil) -> "null"
    Ok(#(_, rest)) -> extract_json_value(string.trim_start(rest))
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
// Tool definitions — imported from cairn/tools
// ---------------------------------------------------------------------------
// All tool schemas are defined in tools.gleam.
// daemon uses tools.daemon_tools_json() for the tools/list response.
