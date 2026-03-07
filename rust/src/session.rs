use fragmentation::fragment::{self, Fragment};
use fragmentation::ref_::Ref as FragRef;
use fragmentation::sha;
use fragmentation::witnessed::{Author, Committer, Message, Timestamp, Witnessed};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct SessionConfig {
    pub author: String,
    pub name: String,
    pub timestamp: Option<String>,
}

#[derive(Debug)]
pub enum Ref {
    Act(String),
    Dec(String),
    Obs(String),
}

impl Ref {
    pub fn sha(&self) -> &str {
        match self {
            Ref::Act(s) | Ref::Dec(s) | Ref::Obs(s) => s,
        }
    }
}

pub struct Session {
    config: SessionConfig,
    store: Vec<(String, Fragment)>,
    last_root: Option<(Fragment, String)>,
    head: String,
}

impl Session {
    pub fn new(config: SessionConfig) -> Self {
        Session {
            config,
            store: Vec::new(),
            last_root: None,
            head: String::new(),
        }
    }

    pub fn head(&self) -> &str {
        &self.head
    }

    pub fn config(&self) -> &SessionConfig {
        &self.config
    }

    pub fn last_root(&self) -> Option<(&Fragment, &str)> {
        self.last_root.as_ref().map(|(f, s)| (f, s.as_str()))
    }

    pub fn fragments_for_ref(&self, r: &Ref) -> Vec<&Fragment> {
        let target = r.sha();
        self.store
            .iter()
            .filter_map(|(sha, frag)| if sha == target { Some(frag) } else { None })
            .collect()
    }

    pub fn act(&mut self, annotation: &str, data: &str) -> Ref {
        let w = self.witnessed(annotation);
        let content = format!("{}\n{}", annotation, data);
        let frag = Fragment::shard(FragRef::new(sha::hash(&content), "act"), w, data);
        let sha = fragment::hash_fragment(&frag);
        self.store.push((sha.clone(), frag));
        self.head = sha.clone();
        Ref::Act(sha)
    }

    pub fn decide(
        &mut self,
        annotation: &str,
        obs_ref: &Ref,
        rule: &str,
        acts: &[Fragment],
    ) -> Ref {
        let obs_sha = obs_ref.sha();
        let w = self.witnessed(annotation);
        let children_sha = children_sha_str(acts);
        let content = format!("{}{}{}", obs_sha, rule, children_sha);
        let frag = Fragment::new_fragment(
            FragRef::new(sha::hash(&content), "dec"),
            w,
            rule,
            acts.to_vec(),
        );
        let sha = fragment::hash_fragment(&frag);
        self.store.push((sha.clone(), frag));
        self.head = sha.clone();
        Ref::Dec(sha)
    }

    pub fn observe(
        &mut self,
        annotation: &str,
        ref_str: &str,
        data: &str,
        decisions: &[Fragment],
    ) -> Ref {
        let w = self.witnessed(annotation);
        let children_sha = children_sha_str(decisions);
        let content = format!("{}{}{}", ref_str, data, children_sha);
        let frag = Fragment::new_fragment(
            FragRef::new(sha::hash(&content), "obs"),
            w,
            data,
            decisions.to_vec(),
        );
        let sha = fragment::hash_fragment(&frag);
        self.store.push((sha.clone(), frag));
        self.head = sha.clone();
        Ref::Obs(sha)
    }

    pub fn commit(&mut self, annotation: &str, observations: &[Fragment]) -> (Fragment, String) {
        let name = &self.config.name;
        let w = self.witnessed(annotation);
        let children_sha = children_sha_str(observations);
        let content = format!("{}{}", name, children_sha);
        let root = Fragment::new_fragment(
            FragRef::new(sha::hash(&content), "root"),
            w,
            name.clone(),
            observations.to_vec(),
        );
        let sha = fragment::hash_fragment(&root);
        self.last_root = Some((root.clone(), sha.clone()));
        self.head = sha.clone();
        (root, sha)
    }

    fn witnessed(&self, message: &str) -> Witnessed {
        let ts = match &self.config.timestamp {
            Some(t) => t.clone(),
            None => SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
                .to_string(),
        };
        Witnessed::new(
            Author(self.config.author.clone()),
            Committer("cairn".into()),
            Timestamp(ts),
            Message(message.into()),
        )
    }
}

fn children_sha_str(fragments: &[Fragment]) -> String {
    fragments
        .iter()
        .map(fragment::hash_fragment)
        .fold(String::new(), |acc, h| acc + &h)
}
