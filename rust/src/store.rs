use fragmentation::fragment::{self, Fragment};
use fragmentation::walk;
use std::fs;
use std::io;
use std::path::Path;

pub fn write(frag: &Fragment, dir: &str) -> io::Result<()> {
    fragmentation::git::write(frag, dir)
}

pub fn verify(root: &Fragment, dir: &str) -> Result<(), String> {
    let frags = walk::collect(root);
    for frag in frags {
        check_one(frag, dir)?;
    }
    Ok(())
}

fn check_one(frag: &Fragment, dir: &str) -> Result<(), String> {
    let sha = fragment::hash_fragment(frag);
    let expected = fragment::serialize(frag);
    let path = Path::new(dir).join(&sha);
    match fs::read_to_string(&path) {
        Err(_) => Err(format!("missing: {}", sha)),
        Ok(on_disk) => {
            if on_disk == expected {
                Ok(())
            } else {
                Err(format!("tampered: {}", sha))
            }
        }
    }
}
