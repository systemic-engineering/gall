import gall/session
import gleeunit/should

// ---------------------------------------------------------------------------
// record_read HEAD advancement
// ---------------------------------------------------------------------------

/// After an act (which is what record_read uses internally), session HEAD
/// must advance. This test catches the bug where s2 was discarded.
pub fn act_advances_head_test() {
  let config =
    session.SessionConfig(
      author: "reed@systemic.engineering",
      name: "read-test",
    )
  let s = session.new(config)

  // Fresh session has empty head
  session.head(s) |> should.equal("")

  // After act, head should be non-empty (the SHA of the new fragment)
  let #(s2, ref) = session.act(s, "@read", "file: src/gall/tools.gleam")
  let sha = session.ref_sha(ref)
  session.head(s2) |> should.equal(sha)
  session.head(s2) |> should.not_equal("")
}

/// Two sequential acts should produce different HEADs.
pub fn sequential_acts_advance_head_test() {
  let config =
    session.SessionConfig(
      author: "reed@systemic.engineering",
      name: "read-test",
    )
  let s = session.new(config)

  let #(s2, _) = session.act(s, "@read", "file: src/a.gleam")
  let head1 = session.head(s2)

  let #(s3, _) = session.act(s2, "@read", "file: src/b.gleam")
  let head2 = session.head(s3)

  head1 |> should.not_equal("")
  head2 |> should.not_equal("")
  head1 |> should.not_equal(head2)
}
