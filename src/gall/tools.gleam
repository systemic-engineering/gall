// Tool schema definitions for the gall MCP protocol.
//
// Both daemon.gleam (stdio MCP) and mcp.gleam (unix socket MCP) import
// tool schemas from here instead of defining them inline. Single source
// of truth for tool names, descriptions, and input schemas.
//
// Two tool sets:
//   - ADO tools: observe, decide, act, commit — session-scoped witnessing
//   - Git tools: status, diff, log, blame, show_file — always available
//
// daemon.gleam exposes both sets. mcp.gleam exposes ADO only.

// ---------------------------------------------------------------------------
// Tool name constants
// ---------------------------------------------------------------------------

/// All tool names, in the order they appear in the daemon's tools/list.
pub fn tool_names() -> List(String) {
  list_append(ado_tool_names(), git_tool_names())
}

/// ADO witnessing tool names.
pub fn ado_tool_names() -> List(String) {
  ["observe", "decide", "act", "commit"]
}

/// Git tool names (daemon-only).
pub fn git_tool_names() -> List(String) {
  ["git_status", "git_diff", "git_log", "git_blame", "git_show_file"]
}

// ---------------------------------------------------------------------------
// Composed tool lists (for tools/list responses)
// ---------------------------------------------------------------------------

/// Full tool list for daemon mode (ADO + git).
pub fn daemon_tools_json() -> String {
  "{\"tools\":["
  <> observe_schema()
  <> ","
  <> decide_schema()
  <> ","
  <> act_schema()
  <> ","
  <> commit_schema()
  <> ","
  <> git_status_schema()
  <> ","
  <> git_diff_schema()
  <> ","
  <> git_log_schema()
  <> ","
  <> git_blame_schema()
  <> ","
  <> git_show_file_schema()
  <> "]}"
}

/// Tool list for MCP mode (ADO only, uses mcp_commit_schema which requires name).
pub fn mcp_tools_json() -> String {
  "{\"tools\":["
  <> observe_schema()
  <> ","
  <> decide_schema()
  <> ","
  <> act_schema()
  <> ","
  <> mcp_commit_schema()
  <> "]}"
}

// ---------------------------------------------------------------------------
// ADO tool schemas
// ---------------------------------------------------------------------------

pub fn observe_schema() -> String {
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

pub fn decide_schema() -> String {
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

pub fn act_schema() -> String {
  "{\"name\":\"act\","
  <> "\"description\":\"Record an action taken.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"Signal kind + summary. What drain filters on. e.g. '@work uphill_late'\"},"
  <> "\"data\":{\"type\":\"string\","
  <> "\"description\":\"Structured payload. e.g. 'state:uphill_late\\nid:42\\nscope:src/signal.gleam'\"}},"
  <> "\"required\":[\"annotation\"]}}"
}

pub fn commit_schema() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session and commit to gestalt. Call once at the end of the task.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"observations\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"obs_sha values to seal as the session root's children.\"}},"
  <> "\"required\":[]}}"
}

/// MCP-mode commit schema. Requires a session name (unlike daemon mode).
pub fn mcp_commit_schema() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session. Call once at the end of the task.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"name\":{\"type\":\"string\","
  <> "\"description\":\"Session name.\"},"
  <> "\"observations\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"obs_sha values to seal as the session root's children.\"}},"
  <> "\"required\":[\"name\"]}}"
}

// ---------------------------------------------------------------------------
// Git tool schemas (daemon-only)
// ---------------------------------------------------------------------------

pub fn git_status_schema() -> String {
  "{\"name\":\"git_status\","
  <> "\"description\":\"Show working tree status of the current project.\","
  <> "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}"
}

pub fn git_diff_schema() -> String {
  "{\"name\":\"git_diff\","
  <> "\"description\":\"Show unstaged changes. Optional path filter.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"Optional file path filter.\"}}}}"
}

pub fn git_log_schema() -> String {
  "{\"name\":\"git_log\","
  <> "\"description\":\"Show recent commit history. Optional path filter and count.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"Optional file path filter.\"},"
  <> "\"n\":{\"type\":\"string\",\"description\":\"Number of commits (default 20).\"}}}"
  <> "}"
}

pub fn git_blame_schema() -> String {
  "{\"name\":\"git_blame\","
  <> "\"description\":\"Show per-line commit attribution for a file. Records a @read annotation in the current session.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"File path relative to project root.\"}},"
  <> "\"required\":[\"path\"]}}"
}

pub fn git_show_file_schema() -> String {
  "{\"name\":\"git_show_file\","
  <> "\"description\":\"Show file content at a given ref. Records a @read annotation in the current session.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"path\":{\"type\":\"string\",\"description\":\"File path relative to project root.\"},"
  <> "\"ref\":{\"type\":\"string\",\"description\":\"Git ref (default HEAD).\"}},"
  <> "\"required\":[\"path\"]}}"
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn list_append(a: List(String), b: List(String)) -> List(String) {
  case a {
    [] -> b
    [first, ..rest] -> [first, ..list_append(rest, b)]
  }
}
