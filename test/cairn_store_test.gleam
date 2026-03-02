import fragmentation
import cairn/store
import gleeunit/should
import simplifile

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn test_dir(suffix: String) -> String {
  "/tmp/cairn_store_test_" <> suffix
}

fn fixed_witnessed() -> fragmentation.Witnessed {
  fragmentation.witnessed(
    fragmentation.Author("test@systemic.engineering"),
    fragmentation.Committer("cairn"),
    fragmentation.Timestamp("1740000000"),
    fragmentation.Message("test"),
  )
}

fn make_shard(data: String) -> fragmentation.Fragment {
  let r = fragmentation.ref(fragmentation.hash(data), "act")
  fragmentation.shard(r, fixed_witnessed(), data)
}

fn make_fragment(
  data: String,
  children: List(fragmentation.Fragment),
) -> fragmentation.Fragment {
  let children_sha =
    children
    |> list.map(fragmentation.hash_fragment)
    |> string.join("")
  let r = fragmentation.ref(fragmentation.hash(data <> children_sha), "obs")
  fragmentation.fragment(r, fixed_witnessed(), data, children)
}

import gleam/list
import gleam/string

// ---------------------------------------------------------------------------
// write_creates_file_test
//
// write produces a SHA-named file under the store directory.
// ---------------------------------------------------------------------------

pub fn write_creates_file_test() {
  let dir = test_dir("write")
  let _ = simplifile.create_directory(dir)
  let frag = make_shard("write-test")
  let sha = fragmentation.hash_fragment(frag)

  store.write(frag, dir) |> should.be_ok()

  simplifile.is_file(dir <> "/" <> sha) |> should.equal(Ok(True))
}

// ---------------------------------------------------------------------------
// verify_passes_when_all_written_test
//
// After writing all fragments in a tree eagerly, verify returns Ok.
// ---------------------------------------------------------------------------

pub fn verify_passes_when_all_written_test() {
  let dir = test_dir("verify_pass")
  let _ = simplifile.create_directory(dir)

  let act = make_shard("act-data")
  let dec = make_fragment("dec-data", [act])
  let obs = make_fragment("obs-data", [dec])
  let root = make_fragment("root-data", [obs])

  // Eager writes — same order as cairn would do during a session
  store.write(act, dir) |> should.be_ok()
  store.write(dec, dir) |> should.be_ok()
  store.write(obs, dir) |> should.be_ok()
  store.write(root, dir) |> should.be_ok()

  store.verify(root, dir) |> should.be_ok()
}

// ---------------------------------------------------------------------------
// verify_fails_when_fragment_missing_test
//
// If a fragment file is absent, verify returns Error("missing: <sha>").
// ---------------------------------------------------------------------------

pub fn verify_fails_when_fragment_missing_test() {
  let dir = test_dir("verify_missing")
  let _ = simplifile.create_directory(dir)

  let act = make_shard("missing-act")
  let root = make_fragment("missing-root", [act])

  // Write root only — act is missing from disk
  store.write(root, dir) |> should.be_ok()
  // Do NOT write act

  let result = store.verify(root, dir)
  result |> should.be_error()
}

// ---------------------------------------------------------------------------
// verify_fails_when_fragment_tampered_test
//
// If a fragment file contains wrong content, verify returns Error("tampered: <sha>").
// ---------------------------------------------------------------------------

pub fn verify_fails_when_fragment_tampered_test() {
  let dir = test_dir("verify_tamper")
  let _ = simplifile.create_directory(dir)

  let frag = make_shard("tamper-target")
  let sha = fragmentation.hash_fragment(frag)

  // Write wrong content at the expected SHA path
  let _ = simplifile.write(dir <> "/" <> sha, "not the real content")

  let result = store.verify(frag, dir)
  result |> should.be_error()
}
