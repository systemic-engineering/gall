// Tool schema definitions for the cairn MCP protocol.
//
// Both daemon.gleam (stdio MCP) and mcp.gleam (unix socket MCP) import
// tool schemas from here instead of defining them inline. Single source
// of truth for tool names, descriptions, and input schemas.
//
// Two tool sets:
//   - Bias tools: bias, commit — session-scoped witnessing
//   - Git tools: status, diff, log, blame, show_file — always available

// ---------------------------------------------------------------------------
// Tool name constants
// ---------------------------------------------------------------------------

/// All tool names, in the order they appear in the daemon's tools/list.
pub fn tool_names() -> List(String) {
  list_append(bias_tool_names(), git_tool_names())
}

/// Bias witnessing tool names.
pub fn bias_tool_names() -> List(String) {
  ["bias", "commit"]
}

/// Git tool names (daemon-only).
pub fn git_tool_names() -> List(String) {
  ["git_status", "git_diff", "git_log", "git_blame", "git_show_file"]
}

// ---------------------------------------------------------------------------
// Composed tool lists (for tools/list responses)
// ---------------------------------------------------------------------------

/// Full tool list for daemon mode (bias + git).
pub fn daemon_tools_json() -> String {
  "{\"tools\":["
  <> bias_schema()
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

/// Tool list for MCP mode (bias + commit only).
pub fn mcp_tools_json() -> String {
  "{\"tools\":["
  <> bias_schema()
  <> ","
  <> mcp_commit_schema()
  <> "]}"
}

// ---------------------------------------------------------------------------
// Bias tool schema
// ---------------------------------------------------------------------------

pub fn bias_schema() -> String {
  "{\"name\":\"bias\","
  <> "\"description\":\"Observation filtered through subjectivity, made structural. Observe first. Decide from observation. Act from decision.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"Signal kind. What drain filters on.\"},"
  <> "\"observation\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"ref\":{\"type\":\"string\",\"description\":\"Where you observed it. Resolved to SHA at submit.\"},"
  <> "\"payload\":{\"type\":\"string\",\"description\":\"What you observed.\"}},"
  <> "\"required\":[\"ref\",\"payload\"]},"
  <> "\"decision\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\",\"description\":\"Signal kind for the decision.\"},"
  <> "\"payload\":{\"type\":\"string\",\"description\":\"What you concluded from observation.\"}},"
  <> "\"required\":[\"payload\"]},"
  <> "\"action\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\",\"description\":\"Signal kind for the action. @exec for shell commands.\"},"
  <> "\"payload\":{\"type\":\"string\",\"description\":\"The action. For @exec: the shell command.\"}},"
  <> "\"required\":[\"payload\"]}},"
  <> "\"required\":[\"annotation\",\"observation\"]}}"
}

// ---------------------------------------------------------------------------
// Commit schema
// ---------------------------------------------------------------------------

pub fn commit_schema() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session and commit to gestalt.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"Signal kind for the commit.\"},"
  <> "\"observations\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"obs_sha values to seal.\"}},"
  <> "\"required\":[\"annotation\"]}}"
}

/// MCP-mode commit schema. Requires a session name (unlike daemon mode).
pub fn mcp_commit_schema() -> String {
  "{\"name\":\"commit\","
  <> "\"description\":\"Seal the session.\","
  <> "\"inputSchema\":{\"type\":\"object\","
  <> "\"properties\":{"
  <> "\"annotation\":{\"type\":\"string\","
  <> "\"description\":\"Signal kind for the commit.\"},"
  <> "\"name\":{\"type\":\"string\","
  <> "\"description\":\"Session name.\"},"
  <> "\"observations\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},"
  <> "\"description\":\"obs_sha values to seal.\"}},"
  <> "\"required\":[\"annotation\",\"name\"]}}"
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
