/// Gall: witnessed AI work. In git. The audacity.
///
/// gall spawns claude. Not the other way around.
/// gall provides the infrastructure for observation.
///
/// What gall does:
///   1. Start a unix socket MCP server.
///   2. Write an MCP config pointing at the socket.
///   3. Spawn claude with that config — claude calls gall's tools.
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
import gall/mcp
import gall/session
import gall/store
import gleam/int
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
}

@external(erlang, "gall_ffi", "session_id")
fn session_id() -> String

@external(erlang, "gall_ffi", "start_unix_socket")
fn start_unix_socket(path: String) -> Result(McpSocket, String)

@external(erlang, "gall_ffi", "accept_client")
fn accept_client(listen_sock: McpSocket) -> Result(McpSocket, String)

@external(erlang, "gall_ffi", "set_active")
fn set_active(sock: McpSocket) -> Nil

@external(erlang, "gall_ffi", "send_socket")
fn send_socket(sock: McpSocket, data: String) -> Nil

@external(erlang, "gall_ffi", "spawn_claude")
fn spawn_claude(exe: String, args: List(String)) -> ClaudePort

@external(erlang, "gall_ffi", "receive_event")
fn receive_event(port: ClaudePort, sock: McpSocket) -> Event

@external(erlang, "gall_ffi", "now")
fn now() -> Int

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

pub type RunConfig {
  RunConfig(
    /// The agent's nickname. Becomes Author("<nickname>@systemic.engineering").
    nickname: String,
    /// The task prompt to pass to claude.
    prompt: String,
    /// Root directory for .gall/ storage. Usually the project working dir.
    work_dir: String,
    /// Path to the claude binary.
    claude_exe: String,
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
  let sid = session_id()
  let base = config.work_dir <> "/.gall/" <> config.nickname <> "/" <> sid
  let store_dir = base <> "/store"
  let sock_path = base <> "/mcp.sock"
  let mcp_config_path = base <> "/mcp.json"

  // Create store directory
  let _ = simplifile.create_directory_all(store_dir)

  // Start unix socket listener
  let assert Ok(listen_sock) = start_unix_socket(sock_path)

  // Write MCP config for claude
  write_mcp_config(mcp_config_path, sock_path)

  // Spawn claude — it connects back to our socket
  let port =
    spawn_claude(config.claude_exe, [
      "--mcp-config",
      mcp_config_path,
      "-p",
      config.prompt,
    ])

  // Accept the MCP connection from claude
  let assert Ok(conn_sock) = accept_client(listen_sock)
  let _ = set_active(conn_sock)

  // Initial MCP state
  let mcp_state = mcp.Uninitialized

  // Run the event loop
  let #(final_mcp_state, exit_code) =
    event_loop(mcp_state, port, conn_sock, store_dir, [])

  // Final verification pass
  case get_session_root(final_mcp_state) {
    None ->
      // Session never committed — partial run, no root to verify
      write_exit_record(base, exit_code, "no-commit")
    Some(#(root, _sha)) ->
      case store.verify(root, store_dir) {
        Ok(Nil) -> {
          write_exit_record(base, exit_code, "ok")
          // TODO: git commit to .mara/gestalt
        }
        Error(reason) -> {
          // Tamper detected — write the incident record
          write_exit_record(base, exit_code, "tampered: " <> reason)
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
          event_loop(
            mcp_state,
            port,
            sock,
            store_dir,
            [chunk, ..thought_acc],
          )
        }
      }
    }

    // MCP JSON-RPC message from claude
    McpMessage(data) -> {
      let line = string.trim(data)
      case string.is_empty(line) {
        True -> event_loop(mcp_state, port, sock, store_dir, thought_acc)
        False -> {
          let #(next_state, maybe_response, maybe_frag) =
            mcp.handle(mcp_state, line)
          // Write the new Fragment to disk immediately
          case maybe_frag {
            None -> Nil
            Some(frag) -> {
              let _ = store.write(frag, store_dir)
              Nil
            }
          }
          // Send response back to claude
          case maybe_response {
            None -> Nil
            Some(response) -> send_socket(sock, response)
          }
          event_loop(
            next_state,
            port,
            sock,
            store_dir,
            thought_acc,
          )
        }
      }
    }

    // Claude exited
    AgentExit(code) -> #(mcp_state, code)

    // MCP socket closed (claude disconnected before port exit)
    McpClosed -> event_loop(mcp_state, port, sock, store_dir, thought_acc)

    // Safety timeout — treat as exit
    Timeout -> #(mcp_state, -1)
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
      fragmentation.Committer("gall"),
      fragmentation.Timestamp(ts),
      fragmentation.Message("@thoughts"),
    )
  let r = fragmentation.ref(fragmentation.hash(ts <> chunk), "thought")
  fragmentation.shard(r, w, chunk)
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
    "{\"mcpServers\":{\"gall\":{\"type\":\"socket\",\"path\":\""
    <> sock_path
    <> "\"}}}"
  let _ = simplifile.create_directory_all(dir_of(path))
  let _ = simplifile.write(path, config)
  Nil
}

/// Write an exit record to base/EXIT.
fn write_exit_record(base: String, code: Int, status: String) -> Nil {
  let content =
    "exit_code: "
    <> int.to_string(code)
    <> "\nstatus: "
    <> status
    <> "\n"
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

fn list_drop_last(lst: List(a)) -> List(a) {
  case lst {
    [] -> []
    [_] -> []
    [x, ..rest] -> [x, ..list_drop_last(rest)]
  }
}
