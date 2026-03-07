use cairn::encoding::{Decode, Encode};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn init_repo() -> (tempfile::TempDir, git2::Repository) {
    let dir = tempfile::tempdir().unwrap();
    let repo = git2::Repository::init(dir.path()).unwrap();
    (dir, repo)
}

// ---------------------------------------------------------------------------
// Cairn<E> construction
// ---------------------------------------------------------------------------

#[test]
fn cairn_open() {
    let (_dir, repo) = init_repo();
    let _cairn: cairn::cairn::Cairn<Vec<u8>> = cairn::cairn::Cairn::open(repo, "mara");
}

#[test]
fn cairn_open_default_encoding() {
    let (_dir, repo) = init_repo();
    // Default E = Vec<u8>
    let _cairn = cairn::cairn::Cairn::open(repo, "mara");
    // Type inference: should work without specifying E
    let _: &cairn::cairn::Cairn = &_cairn;
}

// ---------------------------------------------------------------------------
// Observe
// ---------------------------------------------------------------------------

#[test]
fn cairn_observe_creates_commit() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let oid = cairn
        .observe("found a pattern".to_string(), "code-review", None)
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(oid).unwrap();
    assert!(commit.message().unwrap().contains("code-review"));
}

#[test]
fn cairn_observe_content_readable() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let oid = cairn
        .observe("found a pattern".to_string(), "code-review", None)
        .unwrap();
    let content: String = cairn.read(oid).unwrap();
    assert_eq!(content, "found a pattern");
}

#[test]
fn cairn_observe_type_in_trailers() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let oid = cairn
        .observe("data".to_string(), "boundary-violation", None)
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(oid).unwrap();
    let msg = commit.message().unwrap();
    assert!(msg.contains("Observation-Type: boundary-violation"));
    assert!(msg.contains("ODA-Step: observe"));
}

#[test]
fn cairn_observe_author() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let oid = cairn
        .observe("data".to_string(), "test", None)
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(oid).unwrap();
    assert_eq!(commit.author().name(), Some("mara"));
}

#[test]
fn cairn_observe_chain() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs1 = cairn
        .observe("first".to_string(), "test", None)
        .unwrap();
    let obs2 = cairn
        .observe("second".to_string(), "test", Some(obs1))
        .unwrap();
    let repo = cairn.repo();
    let commit2 = repo.find_commit(obs2).unwrap();
    assert_eq!(commit2.parent_count(), 1);
    assert_eq!(commit2.parent_id(0).unwrap(), obs1);
}

// ---------------------------------------------------------------------------
// Decide
// ---------------------------------------------------------------------------

#[test]
fn cairn_decide_parents_observation() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("pattern".to_string(), "code-review", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "apply fix".to_string())
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(dec).unwrap();
    assert_eq!(commit.parent_count(), 1);
    assert_eq!(commit.parent_id(0).unwrap(), obs);
}

#[test]
fn cairn_decide_content_readable() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("pattern".to_string(), "test", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "rationale here".to_string())
        .unwrap();
    let content: String = cairn.read(dec).unwrap();
    assert_eq!(content, "rationale here");
}

#[test]
fn cairn_decide_trailers() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("data".to_string(), "boundary-violation", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "rationale".to_string())
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(dec).unwrap();
    let msg = commit.message().unwrap();
    assert!(msg.contains("ODA-Step: decide"));
    assert!(msg.contains("Observation-Type: boundary-violation"));
}

// ---------------------------------------------------------------------------
// Act
// ---------------------------------------------------------------------------

#[test]
fn cairn_act_parents_decision() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("pattern".to_string(), "code-review", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "fix it".to_string())
        .unwrap();
    let act = cairn
        .act(dec, "patch applied".to_string())
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(act).unwrap();
    assert_eq!(commit.parent_count(), 1);
    assert_eq!(commit.parent_id(0).unwrap(), dec);
}

#[test]
fn cairn_act_content_readable() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("pattern".to_string(), "test", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "rationale".to_string())
        .unwrap();
    let act = cairn
        .act(dec, "the action".to_string())
        .unwrap();
    let content: String = cairn.read(act).unwrap();
    assert_eq!(content, "the action");
}

#[test]
fn cairn_act_trailers() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");
    let obs = cairn
        .observe("data".to_string(), "boundary-violation", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "rationale".to_string())
        .unwrap();
    let act = cairn
        .act(dec, "action".to_string())
        .unwrap();
    let repo = cairn.repo();
    let commit = repo.find_commit(act).unwrap();
    let msg = commit.message().unwrap();
    assert!(msg.contains("ODA-Step: act"));
    assert!(msg.contains("Observation-Type: boundary-violation"));
}

// ---------------------------------------------------------------------------
// Full ODA chain
// ---------------------------------------------------------------------------

#[test]
fn cairn_oda_full_chain() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");

    let obs = cairn
        .observe("code has no tests".to_string(), "code-review", None)
        .unwrap();
    let dec = cairn
        .decide(obs, "add tests first".to_string())
        .unwrap();
    let act = cairn
        .act(dec, "wrote 5 test cases".to_string())
        .unwrap();

    // Verify parent chain: act → dec → obs
    let repo = cairn.repo();
    let act_commit = repo.find_commit(act).unwrap();
    assert_eq!(act_commit.parent_id(0).unwrap(), dec);
    let dec_commit = repo.find_commit(dec).unwrap();
    assert_eq!(dec_commit.parent_id(0).unwrap(), obs);
    let obs_commit = repo.find_commit(obs).unwrap();
    assert_eq!(obs_commit.parent_count(), 0);

    // Verify content round-trips
    assert_eq!(cairn.read::<String>(obs).unwrap(), "code has no tests");
    assert_eq!(cairn.read::<String>(dec).unwrap(), "add tests first");
    assert_eq!(cairn.read::<String>(act).unwrap(), "wrote 5 test cases");
}

// ---------------------------------------------------------------------------
// Vec<u8> encoding (default)
// ---------------------------------------------------------------------------

#[test]
fn cairn_bytes_encoding() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<Vec<u8>> = cairn::cairn::Cairn::open(repo, "mara");
    let data = vec![0xde, 0xad, 0xbe, 0xef];
    let obs = cairn
        .observe(data.clone(), "binary-test", None)
        .unwrap();
    let content: Vec<u8> = cairn.read(obs).unwrap();
    assert_eq!(content, data);
}

// ---------------------------------------------------------------------------
// Custom encoding
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum TestDialect {
    Text(String),
    Finding { file: String, line: u32, msg: String },
}

impl Encode for TestDialect {
    fn encode(&self) -> Vec<u8> {
        match self {
            TestDialect::Text(s) => format!("T:{}", s).into_bytes(),
            TestDialect::Finding { file, line, msg } => {
                format!("F:{}:{}:{}", file, line, msg).into_bytes()
            }
        }
    }
}

impl Decode for TestDialect {
    type Error = String;

    fn decode(bytes: &[u8]) -> Result<Self, Self::Error> {
        let s = std::str::from_utf8(bytes).map_err(|e| e.to_string())?;
        if let Some(rest) = s.strip_prefix("T:") {
            Ok(TestDialect::Text(rest.to_string()))
        } else if let Some(rest) = s.strip_prefix("F:") {
            let parts: Vec<&str> = rest.splitn(3, ':').collect();
            if parts.len() != 3 {
                return Err("invalid finding format".to_string());
            }
            Ok(TestDialect::Finding {
                file: parts[0].to_string(),
                line: parts[1].parse().map_err(|e: std::num::ParseIntError| e.to_string())?,
                msg: parts[2].to_string(),
            })
        } else {
            Err(format!("unknown prefix: {}", s))
        }
    }
}

#[test]
fn cairn_custom_encoding_roundtrip() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<TestDialect> = cairn::cairn::Cairn::open(repo, "mara");

    let finding = TestDialect::Finding {
        file: "src/main.rs".to_string(),
        line: 42,
        msg: "missing error handling".to_string(),
    };

    let obs = cairn
        .observe(finding.clone(), "code-review", None)
        .unwrap();
    let content: TestDialect = cairn.read(obs).unwrap();
    assert_eq!(content, finding);
}

#[test]
fn cairn_custom_encoding_full_oda() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<TestDialect> = cairn::cairn::Cairn::open(repo, "mara");

    let obs = cairn
        .observe(
            TestDialect::Finding {
                file: "lib.rs".to_string(),
                line: 10,
                msg: "no tests".to_string(),
            },
            "code-review",
            None,
        )
        .unwrap();

    let dec = cairn
        .decide(obs, TestDialect::Text("write tests".to_string()))
        .unwrap();

    let act = cairn
        .act(dec, TestDialect::Text("added 3 tests".to_string()))
        .unwrap();

    // Full chain reads back correctly
    let obs_content: TestDialect = cairn.read(obs).unwrap();
    assert_eq!(
        obs_content,
        TestDialect::Finding {
            file: "lib.rs".to_string(),
            line: 10,
            msg: "no tests".to_string(),
        }
    );
    let dec_content: TestDialect = cairn.read(dec).unwrap();
    assert_eq!(dec_content, TestDialect::Text("write tests".to_string()));
    let act_content: TestDialect = cairn.read(act).unwrap();
    assert_eq!(act_content, TestDialect::Text("added 3 tests".to_string()));
}

// ---------------------------------------------------------------------------
// Determinism
// ---------------------------------------------------------------------------

#[test]
fn cairn_observe_deterministic_blob() {
    let (_dir, repo) = init_repo();
    let cairn: cairn::cairn::Cairn<String> = cairn::cairn::Cairn::open(repo, "mara");

    // Same content → same blob OID (content-addressed)
    let obs1 = cairn
        .observe("same content".to_string(), "test", None)
        .unwrap();
    let obs2 = cairn
        .observe("same content".to_string(), "test", None)
        .unwrap();

    let repo = cairn.repo();
    let tree1 = repo.find_commit(obs1).unwrap().tree().unwrap();
    let tree2 = repo.find_commit(obs2).unwrap().tree().unwrap();
    let data1 = tree1.get_name(".data").unwrap().id();
    let data2 = tree2.get_name(".data").unwrap().id();
    assert_eq!(data1, data2);
}
