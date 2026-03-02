/// Telemetry scaffolding for gall.
///
/// Event names follow [:gall, <layer>, <operation>] convention.
/// Uses a simple Erlang FFI that calls :telemetry.execute/3 if available,
/// falling back to a no-op.
///
/// This is scaffolding — the actual emission points get wired when
/// the dispatch layers are built.
import gleam/option.{type Option}

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

pub type Metadata {
  Metadata(
    tool: String,
    path: Option(String),
    sha: Option(String),
    session_id: Option(String),
    duration_ms: Option(Int),
  )
}

// ---------------------------------------------------------------------------
// Event name constants
// ---------------------------------------------------------------------------

/// Event: [:gall, :tool, :call]
pub fn tool_call_event() -> List(String) {
  ["gall", "tool", "call"]
}

/// Event: [:gall, :tool, :result]
pub fn tool_result_event() -> List(String) {
  ["gall", "tool", "result"]
}

// ---------------------------------------------------------------------------
// Emit helpers
// ---------------------------------------------------------------------------

/// Emit a tool_call telemetry event.
pub fn tool_call(name: String, meta: Metadata) -> Nil {
  emit(tool_call_event(), name, meta, option.None)
}

/// Emit a tool_result telemetry event with duration.
pub fn tool_result(name: String, meta: Metadata, duration_ms: Int) -> Nil {
  emit(
    tool_result_event(),
    name,
    Metadata(..meta, duration_ms: option.Some(duration_ms)),
    option.Some(duration_ms),
  )
}

// ---------------------------------------------------------------------------
// Internal emission
// ---------------------------------------------------------------------------

fn emit(
  event: List(String),
  name: String,
  meta: Metadata,
  _duration: Option(Int),
) -> Nil {
  // Scaffolding: calls gall_trace_ffi:execute/3 which either calls
  // :telemetry.execute/3 or is a no-op if telemetry is not available.
  // For now, pure no-op until telemetry dep is added.
  execute_ffi(event, name, meta)
}

@external(erlang, "gall_trace_ffi", "execute")
fn execute_ffi(event: List(String), name: String, meta: Metadata) -> Nil
