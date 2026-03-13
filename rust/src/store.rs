use fragmentation::encoding::Encode;
use fragmentation::fragment::{self, Fragment};
use fragmentation::walk;

pub fn write<E: Encode>(
    frag: &Fragment<E>,
    repo: &git2::Repository,
) -> Result<git2::Oid, git2::Error> {
    fragmentation::git::write_tree(repo, frag)
}

pub fn verify<E: Encode>(root: &Fragment<E>, repo: &git2::Repository) -> Result<(), String> {
    let frags = walk::collect(root);
    for frag in frags {
        check_one(frag, repo)?;
    }
    Ok(())
}

fn check_one<E: Encode>(frag: &Fragment<E>, repo: &git2::Repository) -> Result<(), String> {
    let oid_hex = fragment::content_oid(frag);
    let oid = git2::Oid::from_str(&oid_hex).map_err(|e| format!("invalid oid: {}", e))?;
    repo.find_object(oid, None)
        .map(|_| ())
        .map_err(|_| format!("missing: {}", oid_hex))
}
