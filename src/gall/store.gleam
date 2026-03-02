/// Store: eager Fragment persistence with tamper detection.
///
/// gall writes each Fragment to disk the moment it's created.
/// The final verify pass checks every Fragment in the session tree
/// exists on disk with matching content.
///
/// Security property: an agent can call tools but can't un-call them.
/// The disk record accumulates live. A prompt-injected agent that
/// deletes or modifies files will be caught on exit.
import fragmentation
import fragmentation/git
import fragmentation/walk
import simplifile

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Write a fragment to the store directory, named by its SHA.
/// Idempotent. Same fragment, same file.
pub fn write(
  frag: fragmentation.Fragment,
  dir: String,
) -> Result(Nil, simplifile.FileError) {
  git.write(frag, dir)
}

// ---------------------------------------------------------------------------
// Verify
// ---------------------------------------------------------------------------

/// Verify that every fragment in the tree exists on disk with matching content.
///
/// Walks the in-memory tree from root. For each fragment, checks:
///   1. A file named by the fragment's SHA exists in dir.
///   2. Its content matches the canonical serialization.
///
/// Returns Ok(Nil) if all fragments are present and unmodified.
/// Returns Error("missing: <sha>") or Error("tampered: <sha>") on failure.
pub fn verify(root: fragmentation.Fragment, dir: String) -> Result(Nil, String) {
  walk.collect(root)
  |> do_verify(dir)
}

fn do_verify(
  frags: List(fragmentation.Fragment),
  dir: String,
) -> Result(Nil, String) {
  case frags {
    [] -> Ok(Nil)
    [frag, ..rest] ->
      case check_one(frag, dir) {
        Error(reason) -> Error(reason)
        Ok(Nil) -> do_verify(rest, dir)
      }
  }
}

fn check_one(frag: fragmentation.Fragment, dir: String) -> Result(Nil, String) {
  let sha = fragmentation.hash_fragment(frag)
  let expected = fragmentation.serialize(frag)
  let path = dir <> "/" <> sha
  case simplifile.read(path) {
    Error(_) -> Error("missing: " <> sha)
    Ok(on_disk) ->
      case on_disk == expected {
        True -> Ok(Nil)
        False -> Error("tampered: " <> sha)
      }
  }
}
