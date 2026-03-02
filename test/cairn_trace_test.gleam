import cairn/trace
import gleam/option.{None, Some}
import gleeunit/should

// ---------------------------------------------------------------------------
// Trace event emission — must not crash
// ---------------------------------------------------------------------------

pub fn tool_call_does_not_crash_test() {
  let meta =
    trace.Metadata(
      tool: "bias",
      path: Some("src/cairn/session.gleam"),
      sha: None,
      session_id: Some("test-123"),
      duration_ms: None,
    )
  // Should return Nil without crashing
  trace.tool_call("bias", meta)
  |> should.equal(Nil)
}

pub fn tool_result_does_not_crash_test() {
  let meta =
    trace.Metadata(
      tool: "git_show_file",
      path: Some("src/cairn/daemon.gleam"),
      sha: Some("abc123"),
      session_id: None,
      duration_ms: None,
    )
  trace.tool_result("git_show_file", meta, 42)
  |> should.equal(Nil)
}

pub fn tool_call_with_minimal_metadata_test() {
  let meta =
    trace.Metadata(
      tool: "bias",
      path: None,
      sha: None,
      session_id: None,
      duration_ms: None,
    )
  trace.tool_call("bias", meta)
  |> should.equal(Nil)
}

// ---------------------------------------------------------------------------
// Event name constants
// ---------------------------------------------------------------------------

pub fn event_names_are_correct_test() {
  trace.tool_call_event()
  |> should.equal(["cairn", "tool", "call"])

  trace.tool_result_event()
  |> should.equal(["cairn", "tool", "result"])
}
