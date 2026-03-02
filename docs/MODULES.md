# Modules

Cairn is nine modules. They compose in layers: core orchestration at the top, session state in the middle, protocol and storage at the bottom.

```
cairn                  socket-mode orchestrator
cairn/daemon           stdio MCP server, git tools, gestalt resources
  cairn/session        ADO state machine
  cairn/store          eager write + verification
  cairn/mcp            JSON-RPC protocol handler (socket mode)
  cairn/tools          MCP tool schema definitions
  cairn/config         session config from git tags
  cairn/json           thin FFI to thoas
  cairn/trace          telemetry scaffolding
```

## cairn

Source: `src/cairn.gleam`

The socket-mode orchestrator. Owns the full lifecycle: signal handlers, session ID generation, unix socket listener, MCP config, claude process spawn, event loop, verification, git commit.

The event loop multiplexes two sources: claude's stdout (captured as thought Shards) and the MCP socket (JSON-RPC messages dispatched to `cairn/mcp`). Every Fragment -- whether from a tool call or from stdout capture -- is written to disk immediately via `cairn/store`.

After claude exits, cairn runs the verification pass. Clean sessions are committed to git with a signed tag. Tampered sessions produce a `@violation` Fragment tree containing the full audit trail.

Also handles OS signals: SIGTERM and SIGHUP are caught and delivered as messages. On either signal, cairn writes a `@killed` shard, records the exit status, and shuts down. SIGKILL cannot be caught; eager writes are the defence.

**Types**: `RunConfig` (nickname, prompt, model, work_dir, claude_exe, alex_key), `Event` (Thought, McpMessage, AgentExit, McpClosed, Timeout, Killed).

## cairn/daemon

Source: `src/cairn/daemon.gleam`

The stdio MCP server. Reads JSON-RPC from stdin, writes responses to stdout. Long-lived -- survives across prompts when installed as an MCP server in Claude Code.

Two session states:

- **Idle**: git tools available. Bias and commit return "not initialized."
- **Active**: full tool suite. Created by `initialize`, reset to Idle by `commit`.

Git tools (`git_status`, `git_diff`, `git_log`, `git_blame`, `git_show_file`) are always available regardless of session state. They call through to git commands via Erlang FFI on the project working directory.

`@read` tracking: `git_blame` and `git_show_file` create `@read` Fragments in the current session, annotated with visibility level derived from the file path. Reads are witnessed, not just writes.

Gestalt resources: previous session records are exposed as MCP resources, listed via `resources/list` and readable via `resources/read`. URIs follow `cairn://<branch>/<actor>/<timestamp>`.

**Environment**: `CAIRN_WORKTREE` (overrides PWD), `CAIRN_BRANCH` (overrides git branch detection), `CAIRN_ALEX_KEY` (Alex's signing key), `CAIRN_NICKNAME` (fallback nickname).

## cairn/session

Source: `src/cairn/session.gleam`

The ADO state machine. Builds a Fragment tree bottom-up through four operations: `act`, `decide`, `observe`, `commit`.

```
Fragment(session_name)           <-- root    (commit)
  Fragment(obs_data)             <-- observe (wraps decisions)
    Fragment(dec_rule)           <-- decide  (wraps acts)
      Shard(act_annotation)     <-- act     (terminal)
```

Each operation returns an updated `Session` and a typed `Ref` (ActRef, DecRef, or ObsRef). The ref carries the SHA of the created Fragment. The session stores all fragments internally, keyed by SHA.

`commit` seals the session by building a root Fragment that wraps the top-level observations. Returns the root Fragment and its SHA. The session tracks the last committed root for the verification pass.

The `Session` type is opaque. Construction through `new`, queries through `head`, `config`, `last_root`, `fragments_for_ref`.

Ref formats for observation sources:
- `file:path.gleam`
- `concept:fn:fragment`
- `section:Types`
- `task:scan-corpus`

## cairn/store

Source: `src/cairn/store.gleam`

Eager Fragment persistence with tamper detection. Two operations.

**`write`**: write a Fragment to the store directory, named by its SHA. Delegates to `fragmentation/git.write`. Idempotent -- same Fragment, same file.

**`verify`**: walk the in-memory tree from root. For each Fragment, check that a file named by its SHA exists in the directory and that its content matches the canonical serialization. Returns `Ok(Nil)` or `Error("missing: <sha>")` or `Error("tampered: <sha>")`.

The security property: the agent can call tools but can't un-call them. The disk record accumulates live.

## cairn/mcp

Source: `src/cairn/mcp.gleam`

The JSON-RPC protocol handler for socket mode. Transport-agnostic -- parses JSON, dispatches tools, returns JSON. Never touches the filesystem.

State is either `Uninitialized` or `Ready(session)`. The `handle` function takes the current state and a JSON string, returns a tuple of (next state, optional response string, list of new Fragments).

Dispatches `initialize`, `notifications/initialized`, `tools/list`, and `tools/call`. Tool calls go through `call_tool`, which routes to `bias` or `commit`.

The bias tool implementation mirrors `cairn/daemon`'s -- same cascading constraint, same bottom-up construction. The difference: daemon mode adds `@exec` support and `@read` tracking. Socket mode does not.

## cairn/tools

Source: `src/cairn/tools.gleam`

MCP tool schema definitions. Single source of truth for tool names, descriptions, and input schemas. Both `daemon.gleam` and `mcp.gleam` import schemas from here.

Two tool sets:
- **Bias tools**: `bias`, `commit` -- session-scoped witnessing.
- **Git tools**: `git_status`, `git_diff`, `git_log`, `git_blame`, `git_show_file` -- always available (daemon only).

Two composed lists:
- `daemon_tools_json()` -- bias + git tools.
- `mcp_tools_json()` -- bias + commit only (socket mode gets no git tools).

The bias schema describes the cascading structure: annotation (required), observation (required, with ref and payload), decision (optional), action (optional). The `@exec` annotation on action is described in the schema but enforced in the daemon, not here.

## cairn/config

Source: `src/cairn/config.gleam`

Session configuration parsed from a git tag. Two fields: `sync` (bool) and `sync_remote` (string). Defaults: sync off, remote `garden@systemic.engineering`.

`parse` reads the tag message content. `to_string` serializes back. Unrecognised lines are ignored. Missing keys take defaults. Round-trips cleanly.

## cairn/json

Source: `src/cairn/json.gleam`

Thin FFI wrapper around thoas, a pure-Erlang JSON library. Four functions: `decode`, `encode`, `get_string`, `get_list`. No Gleam version coupling -- thoas works on any Erlang target.

## cairn/trace

Source: `src/cairn/trace.gleam`

Telemetry scaffolding. Event names follow `[:cairn, <layer>, <operation>]` convention. Two events defined: `tool_call` and `tool_result`.

Calls `cairn_trace_ffi:execute/3`, which attempts to call `:telemetry.execute/3` if the telemetry application is available, falling back to a no-op. This is scaffolding -- the emission points get wired when dispatch layers are built.

`Metadata` carries tool name, optional path, optional SHA, optional session ID, and optional duration.

## How They Compose

Socket mode: `cairn` orchestrates. It calls `cairn/mcp.handle` for protocol dispatch, `cairn/store.write` for persistence, `cairn/store.verify` for tamper detection, and the FFI for git operations.

Daemon mode: `cairn/daemon` orchestrates. It calls `cairn/session` directly for ADO state, `cairn/store` for persistence and verification, `cairn/tools` for schema definitions, `cairn/json` for argument parsing, and the FFI for git and shell operations.

Both modes share `cairn/session` (state machine), `cairn/store` (persistence), `cairn/tools` (schemas), and `cairn/config` (sync settings). The protocol layer differs: socket mode uses `cairn/mcp`, daemon mode handles dispatch inline.
