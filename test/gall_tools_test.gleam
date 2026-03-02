import gall/tools
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// Tool schema names
// ---------------------------------------------------------------------------

pub fn tool_names_include_ado_tools_test() {
  let names = tools.tool_names()
  names
  |> should.equal([
    "observe", "decide", "act", "commit", "git_status", "git_diff", "git_log",
    "git_blame", "git_show_file", "exec",
  ])
}

pub fn ado_tool_names_test() {
  let names = tools.ado_tool_names()
  names |> should.equal(["observe", "decide", "act", "commit"])
}

pub fn git_tool_names_test() {
  let names = tools.git_tool_names()
  names
  |> should.equal([
    "git_status", "git_diff", "git_log", "git_blame", "git_show_file",
  ])
}

// ---------------------------------------------------------------------------
// Schema content — observe
// ---------------------------------------------------------------------------

pub fn observe_schema_has_name_test() {
  let schema = tools.observe_schema()
  schema |> string.contains("\"name\":\"observe\"") |> should.be_true()
}

pub fn observe_schema_has_required_fields_test() {
  let schema = tools.observe_schema()
  schema |> string.contains("\"ref\"") |> should.be_true()
  schema |> string.contains("\"data\"") |> should.be_true()
  schema
  |> string.contains("\"required\":[\"ref\",\"data\"]")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// Schema content — decide
// ---------------------------------------------------------------------------

pub fn decide_schema_has_name_test() {
  let schema = tools.decide_schema()
  schema |> string.contains("\"name\":\"decide\"") |> should.be_true()
}

pub fn decide_schema_has_required_fields_test() {
  let schema = tools.decide_schema()
  schema |> string.contains("\"rule\"") |> should.be_true()
  schema |> string.contains("\"required\":[\"rule\"]") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Schema content — act
// ---------------------------------------------------------------------------

pub fn act_schema_has_name_test() {
  let schema = tools.act_schema()
  schema |> string.contains("\"name\":\"act\"") |> should.be_true()
}

pub fn act_schema_has_required_fields_test() {
  let schema = tools.act_schema()
  schema |> string.contains("\"annotation\"") |> should.be_true()
  schema
  |> string.contains("\"required\":[\"annotation\"]")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// Schema content — commit
// ---------------------------------------------------------------------------

pub fn commit_schema_has_name_test() {
  let schema = tools.commit_schema()
  schema |> string.contains("\"name\":\"commit\"") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Schema content — git tools
// ---------------------------------------------------------------------------

pub fn git_status_schema_has_name_test() {
  let schema = tools.git_status_schema()
  schema |> string.contains("\"name\":\"git_status\"") |> should.be_true()
}

pub fn git_diff_schema_has_name_test() {
  let schema = tools.git_diff_schema()
  schema |> string.contains("\"name\":\"git_diff\"") |> should.be_true()
}

pub fn git_log_schema_has_name_test() {
  let schema = tools.git_log_schema()
  schema |> string.contains("\"name\":\"git_log\"") |> should.be_true()
}

pub fn git_blame_schema_has_name_test() {
  let schema = tools.git_blame_schema()
  schema |> string.contains("\"name\":\"git_blame\"") |> should.be_true()
}

pub fn git_show_file_schema_has_name_test() {
  let schema = tools.git_show_file_schema()
  schema |> string.contains("\"name\":\"git_show_file\"") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Composed tool lists
// ---------------------------------------------------------------------------

pub fn daemon_tools_json_contains_all_tools_test() {
  let json = tools.daemon_tools_json()
  json |> string.contains("\"observe\"") |> should.be_true()
  json |> string.contains("\"git_status\"") |> should.be_true()
  json |> string.contains("\"git_show_file\"") |> should.be_true()
}

pub fn mcp_tools_json_contains_ado_only_test() {
  let json = tools.mcp_tools_json()
  json |> string.contains("\"observe\"") |> should.be_true()
  json |> string.contains("\"commit\"") |> should.be_true()
  // MCP tools should NOT contain git tools
  json |> string.contains("\"git_status\"") |> should.be_false()
}
