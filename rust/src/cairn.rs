use std::marker::PhantomData;

use crate::encoding::{Decode, Encode};

#[derive(Debug)]
pub enum CairnError {
    Git(git2::Error),
    Decode(String),
    Missing(String),
}

impl std::fmt::Display for CairnError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            CairnError::Git(e) => write!(f, "git: {}", e),
            CairnError::Decode(e) => write!(f, "decode: {}", e),
            CairnError::Missing(e) => write!(f, "missing: {}", e),
        }
    }
}

impl std::error::Error for CairnError {}

impl From<git2::Error> for CairnError {
    fn from(e: git2::Error) -> Self {
        CairnError::Git(e)
    }
}

pub struct Cairn<E = Vec<u8>> {
    repo: git2::Repository,
    author: String,
    _encoding: PhantomData<E>,
}

impl<E> Cairn<E> {
    pub fn open(repo: git2::Repository, author: &str) -> Self {
        Cairn {
            repo,
            author: author.to_string(),
            _encoding: PhantomData,
        }
    }

    pub fn repo(&self) -> &git2::Repository {
        &self.repo
    }

    /// Read content from a commit, decoded via D::decode().
    pub fn read<D: Decode>(&self, oid: git2::Oid) -> Result<D, CairnError> {
        let commit = self.repo.find_commit(oid)?;
        let tree = commit.tree()?;
        let data_entry = tree
            .get_name(".data")
            .ok_or_else(|| CairnError::Missing(".data entry".to_string()))?;
        let blob = self.repo.find_blob(data_entry.id())?;
        D::decode(blob.content()).map_err(|e| CairnError::Decode(format!("{}", e)))
    }

    fn observation_type(&self, oid: git2::Oid) -> Result<String, CairnError> {
        let commit = self.repo.find_commit(oid)?;
        let msg = commit.message().unwrap_or("");
        for line in msg.lines() {
            if let Some(value) = line.strip_prefix("Observation-Type: ") {
                return Ok(value.to_string());
            }
        }
        Err(CairnError::Missing("Observation-Type trailer".to_string()))
    }

    fn write_commit(
        &self,
        bytes: &[u8],
        message: &str,
        parent: Option<git2::Oid>,
    ) -> Result<git2::Oid, CairnError> {
        let blob_oid = self.repo.blob(bytes)?;
        let mut builder = self.repo.treebuilder(None)?;
        builder.insert(".data", blob_oid, 0o100644)?;
        let tree_oid = builder.write()?;
        let tree = self.repo.find_tree(tree_oid)?;

        let sig =
            git2::Signature::now(&self.author, &format!("{}@systemic.engineer", self.author))?;

        let parents: Vec<git2::Commit> = match parent {
            Some(oid) => vec![self.repo.find_commit(oid)?],
            None => vec![],
        };
        let parent_refs: Vec<&git2::Commit> = parents.iter().collect();

        Ok(self
            .repo
            .commit(None, &sig, &sig, message, &tree, &parent_refs)?)
    }
}

impl<E: Encode> Cairn<E> {
    pub fn observe(
        &self,
        content: E,
        obs_type: &str,
        parent: Option<git2::Oid>,
    ) -> Result<git2::Oid, CairnError> {
        let bytes = content.encode();
        let message = format!(
            "observe: {}\n\nObservation-Type: {}\nODA-Step: observe",
            obs_type, obs_type
        );
        self.write_commit(&bytes, &message, parent)
    }

    pub fn decide(&self, observation: git2::Oid, rationale: E) -> Result<git2::Oid, CairnError> {
        let bytes = rationale.encode();
        let obs_type = self.observation_type(observation)?;
        let message = format!("decide\n\nObservation-Type: {}\nODA-Step: decide", obs_type);
        self.write_commit(&bytes, &message, Some(observation))
    }

    pub fn act(&self, decision: git2::Oid, content: E) -> Result<git2::Oid, CairnError> {
        let bytes = content.encode();
        let obs_type = self.observation_type(decision)?;
        let message = format!("act\n\nObservation-Type: {}\nODA-Step: act", obs_type);
        self.write_commit(&bytes, &message, Some(decision))
    }
}
