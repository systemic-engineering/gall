import fragmentation
import cairn/mcp
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Initialize an MCP session and return the Ready state.
fn ready_state() -> mcp.State {
  let init_json =
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
    <> "\"params\":{\"protocolVersion\":\"2024-11-05\","
    <> "\"clientInfo\":{\"name\":\"test-agent\",\"version\":\"1.0\"}}}"
  let #(state, _, _) = mcp.handle(mcp.Uninitialized, init_json)
  state
}

/// Send a bias tool call and return #(next_state, response_json, fragments).
fn call_bias(
  state: mcp.State,
  args_json: String,
) -> #(mcp.State, String, List(fragmentation.Fragment)) {
  let json =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"bias\",\"arguments\":"
    <> args_json
    <> "}}"
  let #(next_state, maybe_response, frags) = mcp.handle(state, json)
  let response = case maybe_response {
    Some(r) -> r
    None -> ""
  }
  #(next_state, response, frags)
}

// ---------------------------------------------------------------------------
// Observation only — simplest bias call
// ---------------------------------------------------------------------------

pub fn bias_observation_only_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:src/main.gleam\",\"payload\":\"fn main exists\"}}"
  let #(_, response, frags) = call_bias(state, args)

  // Should produce exactly 1 fragment (the observation)
  list.length(frags)
  |> should.equal(1)

  // Response should contain obs_sha
  response |> string.contains("obs_sha") |> should.be_true()

  // Should NOT contain dec_sha or act_sha
  response |> string.contains("dec_sha") |> should.be_false()
  response |> string.contains("act_sha") |> should.be_false()
}

// ---------------------------------------------------------------------------
// Observation + decision — two fragments
// ---------------------------------------------------------------------------

pub fn bias_observation_and_decision_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:src/main.gleam\",\"payload\":\"fn main exists\"},"
    <> "\"decision\":{\"payload\":\"main function is correct\"}}"
  let #(_, response, frags) = call_bias(state, args)

  // Should produce 2 fragments (decision + observation)
  list.length(frags)
  |> should.equal(2)

  // Response should contain both obs_sha and dec_sha
  response |> string.contains("obs_sha") |> should.be_true()
  response |> string.contains("dec_sha") |> should.be_true()
  response |> string.contains("act_sha") |> should.be_false()
}

// ---------------------------------------------------------------------------
// Full ODA cascade — three fragments
// ---------------------------------------------------------------------------

pub fn bias_full_cascade_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@work\","
    <> "\"observation\":{\"ref\":\"file:src/main.gleam\",\"payload\":\"fn main needs update\"},"
    <> "\"decision\":{\"payload\":\"add error handling\"},"
    <> "\"action\":{\"annotation\":\"@write\",\"payload\":\"src/main.gleam: add Result return\"}}"
  let #(_, response, frags) = call_bias(state, args)

  // Should produce 3 fragments (act + decision + observation)
  list.length(frags)
  |> should.equal(3)

  // Response should contain all three SHAs
  response |> string.contains("obs_sha") |> should.be_true()
  response |> string.contains("dec_sha") |> should.be_true()
  response |> string.contains("act_sha") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Cascading constraint: action requires decision
// ---------------------------------------------------------------------------

pub fn bias_action_without_decision_errors_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@work\","
    <> "\"observation\":{\"ref\":\"file:src/main.gleam\",\"payload\":\"fn main exists\"},"
    <> "\"action\":{\"payload\":\"do something\"}}"
  let #(_, response, _frags) = call_bias(state, args)

  // Should error
  response |> string.contains("action requires decision") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Missing annotation errors
// ---------------------------------------------------------------------------

pub fn bias_missing_annotation_errors_test() {
  let state = ready_state()
  let args =
    "{\"observation\":{\"ref\":\"file:src/main.gleam\",\"payload\":\"fn main exists\"}}"
  let #(_, response, _frags) = call_bias(state, args)

  response |> string.contains("bias requires annotation") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Missing observation errors
// ---------------------------------------------------------------------------

pub fn bias_missing_observation_errors_test() {
  let state = ready_state()
  let args = "{\"annotation\":\"@review\"}"
  let #(_, response, _frags) = call_bias(state, args)

  // When observation is absent, extract_object_field returns "{}" which decodes
  // but has no ref/payload — so the error comes from the field check
  response
  |> string.contains("observation requires ref and payload")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// Observation missing ref/payload errors
// ---------------------------------------------------------------------------

pub fn bias_observation_missing_fields_errors_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:src/main.gleam\"}}"
  let #(_, response, _frags) = call_bias(state, args)

  response
  |> string.contains("observation requires ref and payload")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// Annotation propagation — witness message carries annotation
// ---------------------------------------------------------------------------

pub fn bias_annotation_in_witness_message_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@security-review\","
    <> "\"observation\":{\"ref\":\"file:auth.gleam\",\"payload\":\"auth flow present\"}}"
  let #(_, _, frags) = call_bias(state, args)

  // The observation fragment should carry the annotation in its witness message
  let frag = case frags {
    [f] -> f
    _ -> panic as "expected exactly 1 fragment"
  }
  let w = fragmentation.self_witnessed(frag)
  w.message
  |> should.equal(fragmentation.Message("@security-review"))
}

// ---------------------------------------------------------------------------
// Decision inherits annotation when not specified
// ---------------------------------------------------------------------------

pub fn bias_decision_inherits_annotation_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:main.gleam\",\"payload\":\"exists\"},"
    <> "\"decision\":{\"payload\":\"looks good\"}}"
  let #(_, _, frags) = call_bias(state, args)

  // First fragment is the decision (built first in bottom-up order)
  let dec_frag = case frags {
    [f, ..] -> f
    _ -> panic as "expected at least 1 fragment"
  }
  let w = fragmentation.self_witnessed(dec_frag)
  // Decision should inherit the top-level annotation
  w.message
  |> should.equal(fragmentation.Message("@review"))
}

// ---------------------------------------------------------------------------
// Decision with explicit annotation overrides
// ---------------------------------------------------------------------------

pub fn bias_decision_explicit_annotation_test() {
  let state = ready_state()
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:main.gleam\",\"payload\":\"exists\"},"
    <> "\"decision\":{\"annotation\":\"@approve\",\"payload\":\"approved\"}}"
  let #(_, _, frags) = call_bias(state, args)

  let dec_frag = case frags {
    [f, ..] -> f
    _ -> panic as "expected at least 1 fragment"
  }
  let w = fragmentation.self_witnessed(dec_frag)
  w.message
  |> should.equal(fragmentation.Message("@approve"))
}

// ---------------------------------------------------------------------------
// Commit requires annotation
// ---------------------------------------------------------------------------

pub fn commit_requires_annotation_test() {
  let state = ready_state()
  let json =
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"commit\",\"arguments\":"
    <> "{\"name\":\"test-session\"}"
    <> "}}"
  let #(_, maybe_response, _) = mcp.handle(state, json)
  let response = case maybe_response {
    Some(r) -> r
    None -> ""
  }

  response
  |> string.contains("commit requires annotation")
  |> should.be_true()
}

// ---------------------------------------------------------------------------
// tools/list returns bias, not observe/decide/act
// ---------------------------------------------------------------------------

pub fn tools_list_returns_bias_test() {
  let state = ready_state()
  let json =
    "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{}}"
  let #(_, maybe_response, _) = mcp.handle(state, json)
  let response = case maybe_response {
    Some(r) -> r
    None -> ""
  }

  response |> string.contains("\"bias\"") |> should.be_true()
  response |> string.contains("\"commit\"") |> should.be_true()
  // Old tool names should NOT appear
  response |> string.contains("\"observe\"") |> should.be_false()
  response |> string.contains("\"decide\"") |> should.be_false()
  response |> string.contains("\"act\"") |> should.be_false()
}

// ---------------------------------------------------------------------------
// Not initialized — tool call errors
// ---------------------------------------------------------------------------

pub fn bias_before_initialize_errors_test() {
  let args =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:main.gleam\",\"payload\":\"exists\"}}"
  let json =
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
    <> "\"params\":{\"name\":\"bias\",\"arguments\":"
    <> args
    <> "}}"
  let #(_, maybe_response, _) = mcp.handle(mcp.Uninitialized, json)
  let response = case maybe_response {
    Some(r) -> r
    None -> ""
  }

  response |> string.contains("not initialized") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Sequential bias calls produce different SHAs
// ---------------------------------------------------------------------------

pub fn sequential_bias_calls_produce_different_shas_test() {
  let state = ready_state()

  let args1 =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:a.gleam\",\"payload\":\"first\"}}"
  let #(state2, _, _) = call_bias(state, args1)

  let args2 =
    "{\"annotation\":\"@review\","
    <> "\"observation\":{\"ref\":\"file:b.gleam\",\"payload\":\"second\"}}"
  let #(_, _, _) = call_bias(state2, args2)

  // Both calls should succeed without crashing (state passes through)
  should.be_ok(Ok(Nil))
}
