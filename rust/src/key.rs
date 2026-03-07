use base64::Engine;
use ed25519_dalek::SigningKey;
use hmac::{Hmac, Mac};
use sha2::Sha256;

/// Reed's ed25519 public key (32 raw bytes).
/// Root of trust for agent key derivation.
const REED_ROOT_PUBKEY: [u8; 32] = [
    0x27, 0xea, 0xcd, 0xf9, 0x32, 0x30, 0xe3, 0x66, 0xed, 0xbb, 0x1d, 0x6f, 0x01, 0x8b, 0x9a, 0xcc,
    0x8f, 0x4b, 0x9c, 0xa6, 0x2a, 0xb1, 0xa8, 0x12, 0x21, 0x96, 0xda, 0x18, 0xd4, 0x2d, 0xfa, 0x18,
];

pub struct Keypair {
    pub signing_key: SigningKey,
}

/// Derive an ed25519 keypair from Reed's public key + nickname.
///
/// seed = HMAC-SHA256(key=reed_pubkey, data="{nickname}@systemic.engineering")
/// keypair = ed25519(seed)
///
/// Deterministic: same nickname -> same keypair every time.
pub fn derive(nickname: &str) -> Keypair {
    let identity = format!("{}@systemic.engineering", nickname);
    let mut mac = Hmac::<Sha256>::new_from_slice(&REED_ROOT_PUBKEY).unwrap();
    mac.update(identity.as_bytes());
    let seed: [u8; 32] = mac.finalize().into_bytes().into();
    let signing_key = SigningKey::from_bytes(&seed);
    Keypair { signing_key }
}

/// Format an ed25519 keypair as an OpenSSH private key (PEM, unencrypted).
pub fn openssh_private_key(keypair: &Keypair, comment: &str) -> String {
    let pub_key = keypair.signing_key.verifying_key().to_bytes();
    let priv_key = keypair.signing_key.to_bytes();
    let key_type = b"ssh-ed25519";
    let comment_bytes = comment.as_bytes();

    // SSH wire-format string: uint32(len) ++ bytes
    fn ssh_string(data: &[u8]) -> Vec<u8> {
        let len = (data.len() as u32).to_be_bytes();
        let mut out = Vec::with_capacity(4 + data.len());
        out.extend_from_slice(&len);
        out.extend_from_slice(data);
        out
    }

    // Public key blob: string(keytype) ++ string(pubkey)
    let mut pub_blob = ssh_string(key_type);
    pub_blob.extend_from_slice(&ssh_string(&pub_key));

    // Inner private section
    let check: [u8; 4] = [0x2a, 0x2a, 0x2a, 0x2a];
    let mut priv_full = Vec::with_capacity(64);
    priv_full.extend_from_slice(&priv_key);
    priv_full.extend_from_slice(&pub_key);

    let mut inner = Vec::new();
    inner.extend_from_slice(&check);
    inner.extend_from_slice(&check);
    inner.extend_from_slice(&ssh_string(key_type));
    inner.extend_from_slice(&ssh_string(&pub_key));
    inner.extend_from_slice(&ssh_string(&priv_full));
    inner.extend_from_slice(&ssh_string(comment_bytes));

    // Pad to 8-byte boundary (pad bytes: 1,2,3,...)
    let pad_len = match inner.len() % 8 {
        0 => 0,
        n => 8 - n,
    };
    for i in 1..=pad_len {
        inner.push(i as u8);
    }

    // Outer body
    let mut body = Vec::new();
    body.extend_from_slice(b"openssh-key-v1\0");
    body.extend_from_slice(&ssh_string(b"none")); // cipher
    body.extend_from_slice(&ssh_string(b"none")); // kdf
    body.extend_from_slice(&ssh_string(b"")); // kdf options
    body.extend_from_slice(&1u32.to_be_bytes()); // number of keys
    body.extend_from_slice(&ssh_string(&pub_blob));
    body.extend_from_slice(&ssh_string(&inner));

    let b64 = base64::engine::general_purpose::STANDARD.encode(&body);
    let wrapped = wrap_base64(&b64, 70);

    format!(
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n-----END OPENSSH PRIVATE KEY-----\n",
        wrapped
    )
}

/// Format the public key as an OpenSSH authorized_keys line.
pub fn openssh_public_line(keypair: &Keypair, comment: &str) -> String {
    let pub_key = keypair.signing_key.verifying_key().to_bytes();
    let key_type = b"ssh-ed25519";

    fn ssh_string(data: &[u8]) -> Vec<u8> {
        let len = (data.len() as u32).to_be_bytes();
        let mut out = Vec::with_capacity(4 + data.len());
        out.extend_from_slice(&len);
        out.extend_from_slice(data);
        out
    }

    let mut pub_blob = ssh_string(key_type);
    pub_blob.extend_from_slice(&ssh_string(&pub_key));

    let b64 = base64::engine::general_purpose::STANDARD.encode(&pub_blob);
    format!("ssh-ed25519 {} {}\n", b64, comment)
}

fn wrap_base64(b64: &str, width: usize) -> String {
    b64.as_bytes()
        .chunks(width)
        .map(|chunk| std::str::from_utf8(chunk).unwrap())
        .collect::<Vec<_>>()
        .join("\n")
}
