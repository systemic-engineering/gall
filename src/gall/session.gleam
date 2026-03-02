/// Session: ADO state for a witnessed AI session.
///
/// An agent runs with gall wired. Each call — act, decide, observe —
/// materializes a Fragment node. commit seals the session and returns
/// the root Fragment and its SHA. Same inputs, same hash. Content-addressed.
///
/// ADO structure in Fragment terms (built bottom-up):
///   Fragment(session_name)           ← root    (commit)
///     Fragment(obs_data)             ← observe (wraps decisions)
///       Fragment(dec_rule)           ← decide  (wraps acts)
///         Shard(act_annotation)      ← act     (terminal)
///
/// Ref formats for observe:
///   "file:path.gleam"
///   "concept:fn:fragment"
///   "section:Types"
///   "task:scan-corpus"
import fragmentation
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

@external(erlang, "gall_ffi", "now")
fn now() -> Int

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub type SessionConfig {
  SessionConfig(author: String, name: String)
}

/// Typed reference. Carries the SHA and preserves which layer it came from.
pub type Ref {
  ObsRef(sha: String)
  DecRef(sha: String)
  ActRef(sha: String)
}

pub opaque type Session {
  Session(
    config: SessionConfig,
    /// All built fragments, keyed by their SHA for retrieval.
    store: List(#(String, fragmentation.Fragment)),
    /// The last committed root, if commit was called.
    last_root: Option(#(fragmentation.Fragment, String)),
    /// SHA of the most recently created Fragment. Used as default obs_sha
    /// in decide when the agent doesn't supply one. Empty on new session.
    head: String,
  )
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

pub fn new(config: SessionConfig) -> Session {
  Session(config: config, store: [], last_root: None, head: "")
}

/// SHA of the most recently created Fragment. Empty string on a fresh session.
pub fn head(session: Session) -> String {
  session.head
}

/// Get the session config (author, name).
pub fn config(session: Session) -> SessionConfig {
  session.config
}

/// Get the last committed root Fragment and SHA, if commit was called.
pub fn last_root(session: Session) -> Option(#(fragmentation.Fragment, String)) {
  session.last_root
}

// ---------------------------------------------------------------------------
// ADO — build bottom-up: Act → Decide → Observe → Commit
// ---------------------------------------------------------------------------

/// Record an action. Call before decide — acts are passed as children.
/// annotation: signal kind + summary (goes into Witnessed.message, what drain filters on)
///   e.g. "@work uphill_late"
/// data: structured payload (goes into Fragment.data)
///   e.g. "state:uphill_late\nid:42\nscope:src/signal.gleam"
/// Returns updated session and an ActRef.
pub fn act(
  session: Session,
  annotation: String,
  data: String,
) -> #(Session, Ref) {
  let w = witnessed(session.config, annotation)
  let content = annotation <> "\n" <> data
  let frag =
    fragmentation.shard(
      fragmentation.ref(fragmentation.hash(content), "act"),
      w,
      data,
    )
  let sha = fragmentation.hash_fragment(frag)
  let updated =
    Session(
      ..session,
      store: list.append(session.store, [#(sha, frag)]),
      head: sha,
    )
  #(updated, ActRef(sha: sha))
}

/// Record a decision linked to an observation (by ObsRef), wrapping act fragments.
/// rule: the structural conclusion (e.g. "RequiredSection: fn:fragment")
/// acts: the Act-layer Fragments that this decision produced.
/// Returns updated session and a DecRef.
pub fn decide(
  session: Session,
  obs_ref: Ref,
  rule: String,
  acts: List(fragmentation.Fragment),
) -> #(Session, Ref) {
  let obs_sha = ref_sha(obs_ref)
  let w = witnessed(session.config, "decide: " <> obs_sha)
  let children_sha =
    list.map(acts, fragmentation.hash_fragment)
    |> list.fold("", fn(acc, h) { acc <> h })
  let content = obs_sha <> rule <> children_sha
  let frag =
    fragmentation.fragment(
      fragmentation.ref(fragmentation.hash(content), "dec"),
      w,
      rule,
      acts,
    )
  let sha = fragmentation.hash_fragment(frag)
  let updated =
    Session(
      ..session,
      store: list.append(session.store, [#(sha, frag)]),
      head: sha,
    )
  #(updated, DecRef(sha: sha))
}

/// Record an observation, wrapping decision fragments.
/// ref: source location — "file:path.gleam", "concept:fn:fragment", etc.
/// data: what was observed.
/// decisions: the Decide-layer Fragments that this observation produced.
/// Returns updated session and an ObsRef.
pub fn observe(
  session: Session,
  ref: String,
  data: String,
  decisions: List(fragmentation.Fragment),
) -> #(Session, Ref) {
  let w = witnessed(session.config, "observe: " <> ref)
  let children_sha =
    list.map(decisions, fragmentation.hash_fragment)
    |> list.fold("", fn(acc, h) { acc <> h })
  let content = ref <> data <> children_sha
  let frag =
    fragmentation.fragment(
      fragmentation.ref(fragmentation.hash(content), "obs"),
      w,
      data,
      decisions,
    )
  let sha = fragmentation.hash_fragment(frag)
  let updated =
    Session(
      ..session,
      store: list.append(session.store, [#(sha, frag)]),
      head: sha,
    )
  #(updated, ObsRef(sha: sha))
}

/// Seal the session. observations: the top-level Observe Fragments.
/// Returns #(Session, root_fragment, root_sha). Root Fragment is not dropped.
pub fn commit(
  session: Session,
  observations: List(fragmentation.Fragment),
) -> #(Session, fragmentation.Fragment, String) {
  let name = session.config.name
  let w = witnessed(session.config, "commit: " <> name)
  let children_sha =
    list.map(observations, fragmentation.hash_fragment)
    |> list.fold("", fn(acc, h) { acc <> h })
  let content = name <> children_sha
  let root =
    fragmentation.fragment(
      fragmentation.ref(fragmentation.hash(content), "root"),
      w,
      name,
      observations,
    )
  let sha = fragmentation.hash_fragment(root)
  let updated = Session(..session, last_root: Some(#(root, sha)), head: sha)
  #(updated, root, sha)
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Retrieve the Fragment(s) stored under a given Ref's SHA.
/// Returns a list; normally one element.
pub fn fragments_for_ref(
  session: Session,
  r: Ref,
) -> List(fragmentation.Fragment) {
  let target_sha = ref_sha(r)
  list.filter_map(session.store, fn(entry) {
    let #(sha, frag) = entry
    case sha == target_sha {
      True -> Ok(frag)
      False -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn ref_sha(r: Ref) -> String {
  case r {
    ObsRef(sha) -> sha
    DecRef(sha) -> sha
    ActRef(sha) -> sha
  }
}

fn witnessed(config: SessionConfig, message: String) -> fragmentation.Witnessed {
  fragmentation.witnessed(
    fragmentation.Author(config.author),
    fragmentation.Committer("gall"),
    fragmentation.Timestamp(int.to_string(now())),
    fragmentation.Message(message),
  )
}
