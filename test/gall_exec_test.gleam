import gall/tools
import gleam/list
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// exec schema
// ---------------------------------------------------------------------------

pub fn exec_schema_has_name_test() {
  let schema = tools.exec_schema()
  schema |> string.contains("\"name\":\"exec\"") |> should.be_true()
}

pub fn exec_schema_has_required_command_test() {
  let schema = tools.exec_schema()
  schema |> string.contains("\"required\":[\"command\"]") |> should.be_true()
}

// ---------------------------------------------------------------------------
// tool names include exec
// ---------------------------------------------------------------------------

pub fn tool_names_include_exec_test() {
  let names = tools.tool_names()
  names |> list.contains("exec") |> should.be_true()
}

// ---------------------------------------------------------------------------
// daemon_tools_json includes exec
// ---------------------------------------------------------------------------

pub fn daemon_tools_json_contains_exec_test() {
  let json = tools.daemon_tools_json()
  json |> string.contains("\"exec\"") |> should.be_true()
}
