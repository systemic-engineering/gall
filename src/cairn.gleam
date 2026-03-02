/// Cairn: tamper-proof witnessed agent work. Stones stacked to mark "I was here."
///
/// cairn spawns claude. Not the other way around.
/// cairn provides the infrastructure for observation.
///
/// What cairn does:
///   1. Start a unix socket MCP server.
///   2. Write an MCP config pointing at the socket.
///   3. Spawn claude with that config — claude calls cairn's tools.
///   4. Capture claude's stdout line by line as thought Shards.
///      Written to disk the moment they arrive.
///   5. Handle MCP tool calls (observe/decide/act/commit).
///      Written to disk the moment each Fragment is created.
///   6. After claude exits: verify every Fragment in the session tree
///      is on disk, content-identical to memory.
///      One time in a thousand, a prompt-injected agent tries to
///      clean up its own subversion. This pass snaps shut.
///   7. If clean: commit the session tree to .mara/gestalt.
///
/// The disk record exists during the session. Not after. During.
/// That's what makes it witnessing, not logging.
import fragmentation
import fragmentation/walk
import cairn/config as cairn_config
import cairn/mcp
import cairn/session
import cairn/store
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

// ---------------------------------------------------------------------------
// FFI — all the unsafe bits live in Erlang
// ---------------------------------------------------------------------------

pub type ClaudePort

pub type McpSocket

pub type Event {
  Thought(data: String)
  McpMessage(data: String)
  AgentExit(code: Int)
  McpClosed
  Timeout
  Killed
}

@external(erlang, "cairn_ffi", "session_id")
fn session_id() -> String

@external(erlang, "cairn_ffi", "setup_signal_handlers")
fn setup_signal_handlers() -> Nil

@external(erlang, "cairn_ffi", "start_unix_socket")
fn start_unix_socket(path: String) -> Result(McpSocket, String)

@external(erlang, "cairn_ffi", "accept_client")
fn accept_client(listen_sock: McpSocket) -> Result(McpSocket, String)

@external(erlang, "cairn_ffi", "set_active")
fn set_active(sock: McpSocket) -> Nil

@external(erlang, "cairn_ffi", "send_socket")
fn send_socket(sock: McpSocket, data: String) -> Nil

@external(erlang, "cairn_ffi", "spawn_claude")
fn spawn_claude(
  exe: String,
  args: List(String),
  env: List(#(String, String)),
) -> ClaudePort

@external(erlang, "cairn_ffi", "receive_event")
fn receive_event(port: ClaudePort, sock: McpSocket) -> Event

@external(erlang, "cairn_ffi", "now")
fn now() -> Int

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
// Config
// ---------------------------------------------------------------------------

pub type RunConfig {
  RunConfig(
    /// The agent's nickname. Becomes Author("<nickname>@systemic.engineering").
    nickname: String,
    /// The task prompt to pass to claude.
    prompt: String,
    /// The model identifier (e.g. "claude-sonnet-4-6").
    model: String,
    /// Root directory for .cairn/ storage. Usually the project working dir.
    work_dir: String,
    /// Path to the claude binary.
    claude_exe: String,
    /// Path to alex@systemic.engineering's SSH private key for signing.
    /// When set: tags are signed with this key and carry the attestation footer.
    /// When empty: tags are signed with the installation key (.cairn/ssh/id_ed25519).
    alex_key: String,
  )
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() -> Nil {
  // TODO: parse RunConfig from args/env for CLI use.
  // For now: placeholder so `gleam run` doesn't error.
  Nil
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

pub fn run(config: RunConfig) -> Nil {
  // Catch SIGTERM and SIGHUP — deliver as messages, not instant death.
  // SIGKILL cannot be caught; eager writes are our defence there.
  let _ = setup_signal_handlers()

  let sid = session_id()
  let cairn_dir = config.work_dir <> "/.cairn"
  let branch = normalize_branch(git_current_branch(config.work_dir))
  let session_rel =
    "actors/" <> config.nickname <> "/worktrees/" <> branch <> "/" <> sid
  let tag_name = "cairn/" <> branch <> "/" <> config.nickname <> "/" <> sid
  let base = cairn_dir <> "/" <> session_rel
  let store_dir = base <> "/store"
  let sock_path = base <> "/mcp.sock"
  let mcp_config_path = base <> "/mcp.json"

  // Create store directory (no git init — project git tracks .cairn/ as plain files)
  let _ = simplifile.create_directory_all(store_dir)

  // Start unix socket listener
  let assert Ok(listen_sock) = start_unix_socket(sock_path)

  // Write MCP config for claude
  write_mcp_config(mcp_config_path, sock_path)

  // Spawn claude — it connects back to our socket.
  // CAIRN_WORKTREE and CAIRN_BRANCH are set so any daemon spawned by the agent
  // (e.g. via MCP config) knows which worktree and branch it's operating on.
  let port =
    spawn_claude(
      config.claude_exe,
      ["--mcp-config", mcp_config_path, "-p", config.prompt],
      [#("CAIRN_WORKTREE", config.work_dir), #("CAIRN_BRANCH", branch)],
    )

  // Accept the MCP connection from claude
  let assert Ok(conn_sock) = accept_client(listen_sock)
  let _ = set_active(conn_sock)

  // Initial MCP state
  let mcp_state = mcp.Uninitialized

  // Run the event loop
  let #(final_mcp_state, exit_code) =
    event_loop(mcp_state, port, conn_sock, store_dir, [])

  // If cairn was killed by a signal, record it before doing anything else.
  // exit_code -2 = killed. Write @killed to store so it travels into .gestalt.
  case exit_code == -2 {
    True -> {
      let killed_frag = killed_shard(final_mcp_state)
      let _ = store.write(killed_frag, store_dir)
      write_exit_record(base, exit_code, "killed")
    }
    False ->
      // Final verification pass
      case get_session_root(final_mcp_state) {
        None ->
          // Session never committed — partial run, no root to verify
          write_exit_record(base, exit_code, "no-commit")
        Some(#(root, sha)) ->
          case store.verify(root, store_dir) {
            Ok(Nil) -> {
              write_exit_record(base, exit_code, "ok")
              // Commit .cairn/sessions/... into the project's own git.
              // .cairn/ is plain files — no nested git repo.
              let _ = simplifile.create_directory_all(cairn_dir)
              git_commit_session(
                config.work_dir,
                ".cairn/" <> session_rel <> "/store",
                config.nickname,
                sid,
                tag_name,
                sha,
                config.alex_key,
              )
              // Sync if enabled in config tag
              let sync_cfg = cairn_config.parse(read_config_tag(config.work_dir))
              case sync_cfg.sync {
                True -> send_patch(config.work_dir, sync_cfg.sync_remote)
                False -> Nil
              }
            }
            Error(reason) -> {
              // Tamper detected — build the full violation record and write to store
              let violation =
                build_violation(reason, root, store_dir, config, sid)
              let _ = store.write(violation, store_dir)
              write_exit_record(base, exit_code, "violation: " <> reason)
            }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Event loop
// ---------------------------------------------------------------------------

/// Process events from claude's stdout (thoughts) and the MCP socket.
/// Returns the final MCP state and claude's exit code.
fn event_loop(
  mcp_state: mcp.State,
  port: ClaudePort,
  sock: McpSocket,
  store_dir: String,
  thought_acc: List(String),
) -> #(mcp.State, Int) {
  case receive_event(port, sock) {
    // Claude stdout chunk — record as timestamped thought
    Thought(data) -> {
      let chunk = string.trim(data)
      case string.is_empty(chunk) {
        True -> event_loop(mcp_state, port, sock, store_dir, thought_acc)
        False -> {
          let frag = thought_shard(chunk, mcp_state)
          let _ = store.write(frag, store_dir)
          event_loop(mcp_state, port, sock, store_dir, [chunk, ..thought_acc])
        }
      }
    }

    // MCP JSON-RPC message from claude
    McpMessage(data) -> {
      let line = string.trim(data)
      case string.is_empty(line) {
        True -> event_loop(mcp_state, port, sock, store_dir, thought_acc)
        False -> {
          let #(next_state, maybe_response, frags) =
            mcp.handle(mcp_state, line)
          // Write new Fragments to disk immediately
          list.each(frags, fn(frag) {
            let _ = store.write(frag, store_dir)
            Nil
          })
          // Send response back to claude
          case maybe_response {
            None -> Nil
            Some(response) -> send_socket(sock, response)
          }
          event_loop(next_state, port, sock, store_dir, thought_acc)
        }
      }
    }

    // Claude exited
    AgentExit(code) -> #(mcp_state, code)

    // MCP socket closed (claude disconnected before port exit)
    McpClosed -> event_loop(mcp_state, port, sock, store_dir, thought_acc)

    // Safety timeout — treat as exit
    Timeout -> #(mcp_state, -1)

    // OS signal (SIGTERM / SIGHUP) — graceful shutdown.
    // Eager writes mean disk is current. Verify and exit cleanly.
    Killed -> #(mcp_state, -2)
  }
}

// ---------------------------------------------------------------------------
// Thought capture
// ---------------------------------------------------------------------------

/// Wrap a claude stdout chunk as a timestamped Shard.
/// Author = the session agent (if initialized), else "unknown".
fn thought_shard(chunk: String, mcp_state: mcp.State) -> fragmentation.Fragment {
  let author = case mcp_state {
    mcp.Uninitialized -> "unknown@systemic.engineering"
    mcp.Ready(s) -> {
      let session.SessionConfig(author: a, ..) = session.config(s)
      a
    }
  }
  let ts = int.to_string(now())
  let w =
    fragmentation.witnessed(
      fragmentation.Author(author),
      fragmentation.Committer("cairn"),
      fragmentation.Timestamp(ts),
      fragmentation.Message("@thoughts"),
    )
  let r = fragmentation.ref(fragmentation.hash(ts <> chunk), "thought")
  fragmentation.shard(r, w, chunk)
}

/// Record that cairn itself was killed by an OS signal.
/// The session was running. Someone or something sent SIGTERM/SIGHUP.
/// Written to store so it travels into .gestalt regardless of session state.
fn killed_shard(mcp_state: mcp.State) -> fragmentation.Fragment {
  let author = case mcp_state {
    mcp.Uninitialized -> "unknown@systemic.engineering"
    mcp.Ready(s) -> {
      let session.SessionConfig(author: a, ..) = session.config(s)
      a
    }
  }
  let ts = int.to_string(now())
  let w =
    fragmentation.witnessed(
      fragmentation.Author(author),
      fragmentation.Committer("cairn"),
      fragmentation.Timestamp(ts),
      fragmentation.Message("@killed"),
    )
  let r = fragmentation.ref(fragmentation.hash(ts <> "@killed"), "killed")
  fragmentation.shard(r, w, "@killed: cairn received SIGTERM or SIGHUP")
}

/// Build a full @violation Fragment.
///
/// Contains:
///   - prompt and model (the full execution context)
///   - session identity (author, session id)
///   - recorded root SHA (what cairn held in memory)
///   - findings: a Fragment whose children are one Shard per node in the
///     recorded tree, each describing what was actually found on disk:
///     "<sha>: present | missing | tampered\nexpected:...\nfound:..."
///
/// The recorded path is the in-memory Fragment tree.
/// The found path is the disk audit of that same tree.
/// Diff them to see exactly what changed.
fn build_violation(
  reason: String,
  root: fragmentation.Fragment,
  store_dir: String,
  config: RunConfig,
  sid: String,
) -> fragmentation.Fragment {
  let ts = int.to_string(now())
  let root_sha = fragmentation.hash_fragment(root)

  // One Shard per Fragment in the recorded tree, describing the disk state.
  let finding_shards = audit_findings(root, store_dir, ts)

  // Wrap findings in a Fragment so the diff is structurally locatable.
  let findings_frag =
    fragmentation.fragment(
      fragmentation.ref(
        fragmentation.hash("findings" <> ts <> root_sha),
        "findings",
      ),
      violation_witnessed(ts, "@violation findings"),
      "findings",
      finding_shards,
    )

  let children = [
    meta_shard("prompt", config.prompt, ts),
    meta_shard("model", config.model, ts),
    meta_shard("session", config.nickname <> "/" <> sid, ts),
    meta_shard("recorded_root", root_sha, ts),
    findings_frag,
  ]

  fragmentation.fragment(
    fragmentation.ref(fragmentation.hash(ts <> reason), "violation"),
    violation_witnessed(ts, "@violation " <> reason),
    reason,
    children,
  )
}

/// Audit every Fragment in the recorded tree against disk.
/// Returns one finding Shard per node.
fn audit_findings(
  root: fragmentation.Fragment,
  store_dir: String,
  ts: String,
) -> List(fragmentation.Fragment) {
  walk.collect(root)
  |> list.map(fn(frag) {
    let sha = fragmentation.hash_fragment(frag)
    let expected = fragmentation.serialize(frag)
    let path = store_dir <> "/" <> sha
    let finding = case simplifile.read(path) {
      Error(_) -> sha <> ": missing"
      Ok(on_disk) ->
        case on_disk == expected {
          True -> sha <> ": present"
          False ->
            sha
            <> ": tampered\nexpected:\n"
            <> expected
            <> "\nfound:\n"
            <> on_disk
        }
    }
    fragmentation.shard(
      fragmentation.ref(fragmentation.hash(ts <> sha), "finding"),
      violation_witnessed(ts, "@violation finding"),
      finding,
    )
  })
}

fn meta_shard(key: String, value: String, ts: String) -> fragmentation.Fragment {
  let data = key <> ": " <> value
  fragmentation.shard(
    fragmentation.ref(fragmentation.hash(ts <> data), key),
    violation_witnessed(ts, "@violation meta"),
    data,
  )
}

fn violation_witnessed(ts: String, msg: String) -> fragmentation.Witnessed {
  fragmentation.witnessed(
    fragmentation.Author("violation@systemic.engineering"),
    fragmentation.Committer("cairn"),
    fragmentation.Timestamp(ts),
    fragmentation.Message(msg),
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Get the session root Fragment and SHA if the session was committed.
/// Returns None if commit was never called.
fn get_session_root(
  mcp_state: mcp.State,
) -> Option(#(fragmentation.Fragment, String)) {
  case mcp_state {
    mcp.Uninitialized -> None
    mcp.Ready(s) -> session.last_root(s)
  }
}

/// Write an MCP config JSON file telling claude where the socket is.
fn write_mcp_config(path: String, sock_path: String) -> Nil {
  let config =
    "{\"mcpServers\":{\"cairn\":{\"type\":\"socket\",\"path\":\""
    <> sock_path
    <> "\"}}}"
  let _ = simplifile.create_directory_all(dir_of(path))
  let _ = simplifile.write(path, config)
  Nil
}

/// Write an exit record to base/EXIT.
fn write_exit_record(base: String, code: Int, status: String) -> Nil {
  let content =
    "exit_code: " <> int.to_string(code) <> "\nstatus: " <> status <> "\n"
  let _ = simplifile.write(base <> "/EXIT", content)
  Nil
}

fn dir_of(path: String) -> String {
  case string.split(path, "/") {
    [] -> "."
    parts ->
      parts
      |> list_drop_last
      |> string.join("/")
  }
}

fn normalize_branch(branch: String) -> String {
  string.replace(branch, "/", "-")
}

fn list_drop_last(lst: List(a)) -> List(a) {
  case lst {
    [] -> []
    [_] -> []
    [x, ..rest] -> [x, ..list_drop_last(rest)]
  }
}
