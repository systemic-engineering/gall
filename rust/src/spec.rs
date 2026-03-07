use sha2::{Digest, Sha256};

pub struct Spec {
    pub actor: String,
    pub model: String,
    pub prompt: String,
    pub repo: String,
    pub branch: String,
    pub max_turns: Option<u32>,
}

pub struct Actor {
    pub spec: Spec,
    pub hash: String,
    pub identity: String,
}

impl From<Spec> for Actor {
    fn from(spec: Spec) -> Self {
        let canonical = format!(
            "actor:{}\nmodel:{}\nprompt:{}\nrepo:{}\nbranch:{}\nmax_turns:{}",
            spec.actor,
            spec.model,
            spec.prompt,
            spec.repo,
            spec.branch,
            spec.max_turns.map(|n| n.to_string()).unwrap_or_default(),
        );
        let mut hasher = Sha256::new();
        hasher.update(canonical.as_bytes());
        let hash = hex::encode(hasher.finalize());
        let identity = format!("{}@systemic.engineering", spec.actor);
        Actor {
            spec,
            hash,
            identity,
        }
    }
}
