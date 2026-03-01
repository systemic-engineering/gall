import fragmentation
import gall/session
import gleam/list
import gleeunit/should

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

pub fn new_session_is_empty_test() {
  let s = session.new()
  session.observations(s)
  |> should.equal([])
}

// ---------------------------------------------------------------------------
// Observe
// ---------------------------------------------------------------------------

pub fn observe_records_observation_test() {
  let s = session.new()
  let #(s, _id) =
    session.observe(s, "fragmentation.gleam:33", "fn:fragment present in all core files")
  session.observations(s)
  |> list.length
  |> should.equal(1)
}

pub fn observe_returns_sha_as_id_test() {
  let s = session.new()
  let #(_s, id) =
    session.observe(s, "fragmentation.gleam:33", "fn:fragment present in all core files")
  // id is a Sha — same inputs produce same id
  let s2 = session.new()
  let #(_s2, id2) =
    session.observe(s2, "fragmentation.gleam:33", "fn:fragment present in all core files")
  id
  |> should.equal(id2)
}

// ---------------------------------------------------------------------------
// Decide
// ---------------------------------------------------------------------------

pub fn decide_records_decision_test() {
  let s = session.new()
  let #(s, obs_id) =
    session.observe(s, "fragmentation.gleam:33", "fn:fragment present in all core files")
  let #(s, _dec_id) = session.decide(s, obs_id, "RequiredSection: fn:fragment")
  session.decisions(s)
  |> list.length
  |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Act
// ---------------------------------------------------------------------------

pub fn act_records_action_test() {
  let s = session.new()
  let #(s, obs_id) =
    session.observe(s, "fragmentation.gleam:33", "fn:fragment present")
  let #(s, dec_id) = session.decide(s, obs_id, "RequiredSection: fn:fragment")
  let #(s, _act_id) = session.act(s, dec_id, "annotate: fn:fragment is required")
  session.actions(s)
  |> list.length
  |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Commit
// ---------------------------------------------------------------------------

pub fn commit_returns_root_sha_test() {
  let s = session.new()
  let #(s, obs_id) =
    session.observe(s, "fragmentation.gleam:33", "fn:fragment present")
  let #(s, dec_id) = session.decide(s, obs_id, "RequiredSection")
  let #(s, _act_id) = session.act(s, dec_id, "annotate: fn:fragment")
  let #(_s, sha) = session.commit(s, "test")
  // sha is a hex String — non-empty
  sha
  |> should.not_equal("")
}

pub fn commit_is_deterministic_test() {
  let s1 = session.new()
  let #(s1, obs_id) =
    session.observe(s1, "fragmentation.gleam:33", "fn:fragment present")
  let #(s1, dec_id) = session.decide(s1, obs_id, "RequiredSection")
  let #(s1, _) = session.act(s1, dec_id, "annotate: fn:fragment")
  let #(_, sha1) = session.commit(s1, "test")

  let s2 = session.new()
  let #(s2, obs_id2) =
    session.observe(s2, "fragmentation.gleam:33", "fn:fragment present")
  let #(s2, dec_id2) = session.decide(s2, obs_id2, "RequiredSection")
  let #(s2, _) = session.act(s2, dec_id2, "annotate: fn:fragment")
  let #(_, sha2) = session.commit(s2, "test")

  sha1
  |> should.equal(sha2)
}
