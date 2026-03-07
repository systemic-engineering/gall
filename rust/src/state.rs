use crate::spec::Actor;

pub struct SessionRecord {
    pub root_sha: String,
    pub previous: Option<String>,
    pub timestamp: String,
}

pub struct State {
    pub actor: Actor,
    pub sessions: Vec<SessionRecord>,
}

impl State {
    pub fn new(actor: Actor) -> Self {
        State {
            actor,
            sessions: Vec::new(),
        }
    }

    pub fn append(&mut self, root_sha: String, timestamp: String) {
        let previous = self.sessions.last().map(|s| s.root_sha.clone());
        self.sessions.push(SessionRecord {
            root_sha,
            previous,
            timestamp,
        });
    }
}
