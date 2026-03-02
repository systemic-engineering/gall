import cairn/tools
import gleam/list
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// exec is no longer a separate tool — it's a bias action with @exec annotation
// ---------------------------------------------------------------------------

pub fn tool_names_do_not_include_exec_test() {
  let names = tools.tool_names()
  names |> list.contains("exec") |> should.be_false()
}

pub fn daemon_tools_json_does_not_contain_exec_test() {
  let json = tools.daemon_tools_json()
  // "exec" appears inside bias description ("@exec for shell commands")
  // but should NOT appear as a standalone tool name
  json |> string.contains("\"name\":\"exec\"") |> should.be_false()
}
