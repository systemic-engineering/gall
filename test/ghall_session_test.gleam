import fragmentation
import ghall/session
import gleam/list
import gleeunit/should

// ---------------------------------------------------------------------------
// new_session_test
// ---------------------------------------------------------------------------

pub fn new_session_test() {
  let config =
    session.SessionConfig(
      author: "mara@systemic.engineering",
      name: "test-session",
    )
  let s = session.new(config)
  // Session is opaque; we just verify it was created without crashing.
  // A freshly created session should produce a deterministic commit root.
  let #(_s, root, sha) = session.commit(s, [])
  sha
  |> should.not_equal("")
  // Root fragment is not dropped
  fragmentation.data(root)
  |> should.equal("test-session")
}

// ---------------------------------------------------------------------------
// act_returns_act_ref_test
// ---------------------------------------------------------------------------

pub fn act_returns_act_ref_test() {
  let config =
    session.SessionConfig(
      author: "mara@systemic.engineering",
      name: "test-session",
    )
  let s = session.new(config)
  let #(_s, ref) = session.act(s, "do something")
  case ref {
    session.ActRef(_sha) -> should.be_ok(Ok(Nil))
    _ -> should.be_ok(Error("expected ActRef"))
  }
}

// ---------------------------------------------------------------------------
// decide_wraps_acts_test
// ---------------------------------------------------------------------------

pub fn decide_wraps_acts_test() {
  let config =
    session.SessionConfig(author: "reed@systemic.engineering", name: "test")
  let s = session.new(config)

  let #(s, act_ref) = session.act(s, "annotate: fn:fragment")

  // Retrieve the act fragment from session using the ref
  let act_frags = session.fragments_for_ref(s, act_ref)
  list.length(act_frags)
  |> should.equal(1)

  // Build obs_ref for decide
  let obs_ref = session.ObsRef(sha: "placeholder-obs")
  let #(_s, dec_ref2) =
    session.decide(s, obs_ref, "RequiredSection: fn:fragment", act_frags)

  case dec_ref2 {
    session.DecRef(_sha) -> should.be_ok(Ok(Nil))
    _ -> should.be_ok(Error("expected DecRef"))
  }
}

// ---------------------------------------------------------------------------
// observe_wraps_decisions_test
// ---------------------------------------------------------------------------

pub fn observe_wraps_decisions_test() {
  let config =
    session.SessionConfig(author: "mara@systemic.engineering", name: "test")
  let s = session.new(config)

  // Build a decision fragment
  let obs_ref = session.ObsRef(sha: "placeholder-obs")
  let #(s, dec_ref) =
    session.decide(s, obs_ref, "RequiredSection: fn:fragment", [])
  let dec_frags = session.fragments_for_ref(s, dec_ref)
  list.length(dec_frags)
  |> should.equal(1)

  // Observe wraps those decisions
  let #(_s, obs_ref2) =
    session.observe(s, "concept:fn:fragment", "fn:fragment present", dec_frags)

  case obs_ref2 {
    session.ObsRef(_sha) -> should.be_ok(Ok(Nil))
    _ -> should.be_ok(Error("expected ObsRef"))
  }
}

// ---------------------------------------------------------------------------
// commit_returns_fragment_test
// ---------------------------------------------------------------------------

pub fn commit_returns_fragment_test() {
  let config =
    session.SessionConfig(
      author: "mara@systemic.engineering",
      name: "my-session",
    )
  let s = session.new(config)
  let #(_s, root_frag, root_sha) = session.commit(s, [])

  // root_frag is a Fragment (not dropped)
  root_sha
  |> should.not_equal("")

  // Root data is the session name
  fragmentation.data(root_frag)
  |> should.equal("my-session")
}

// ---------------------------------------------------------------------------
// commit_deterministic_test
// ---------------------------------------------------------------------------

pub fn commit_deterministic_test() {
  // Build two identical sessions and verify same root SHA
  let config =
    session.SessionConfig(
      author: "mara@systemic.engineering",
      name: "det-session",
    )

  let s1 = session.new(config)
  let #(s1, act_ref1) = session.act(s1, "annotate: fn:fragment")
  let act_frags1 = session.fragments_for_ref(s1, act_ref1)
  let obs_ref1 = session.ObsRef(sha: "obs1")
  let #(s1, dec_ref1b) =
    session.decide(s1, obs_ref1, "RequiredSection", act_frags1)
  let dec_frags1 = session.fragments_for_ref(s1, dec_ref1b)
  let #(s1, obs_ref1b) =
    session.observe(
      s1,
      "concept:fn:fragment",
      "fn:fragment present",
      dec_frags1,
    )
  let obs_frags1 = session.fragments_for_ref(s1, obs_ref1b)
  let #(_s1, _root1, sha1) = session.commit(s1, obs_frags1)

  let s2 = session.new(config)
  let #(s2, act_ref2) = session.act(s2, "annotate: fn:fragment")
  let act_frags2 = session.fragments_for_ref(s2, act_ref2)
  let obs_ref2 = session.ObsRef(sha: "obs1")
  let #(s2, dec_ref2b) =
    session.decide(s2, obs_ref2, "RequiredSection", act_frags2)
  let dec_frags2 = session.fragments_for_ref(s2, dec_ref2b)
  let #(s2, obs_ref2b) =
    session.observe(
      s2,
      "concept:fn:fragment",
      "fn:fragment present",
      dec_frags2,
    )
  let obs_frags2 = session.fragments_for_ref(s2, obs_ref2b)
  let #(_s2, _root2, sha2) = session.commit(s2, obs_frags2)

  sha1
  |> should.equal(sha2)
}

// ---------------------------------------------------------------------------
// author_from_config_test
// ---------------------------------------------------------------------------

pub fn author_from_config_test() {
  let config =
    session.SessionConfig(
      author: "reed@systemic.engineering",
      name: "auth-test",
    )
  let s = session.new(config)
  let #(s, act_ref) = session.act(s, "some action")
  let act_frags = session.fragments_for_ref(s, act_ref)
  let frag = case act_frags {
    [f, ..] -> f
    [] -> panic as "expected at least one fragment"
  }
  let w = fragmentation.self_witnessed(frag)
  // Author must be the agent, not "gall"
  w.author
  |> should.equal(fragmentation.Author("reed@systemic.engineering"))
}
