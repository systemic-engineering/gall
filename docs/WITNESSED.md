# Witnessed

Cairn's trust model is built on three properties: deterministic key derivation, mandatory verification, and the principle that tampering produces its own record.

## Agent Key Derivation

Every agent gets a unique ed25519 keypair. The keypair is not generated randomly. It is derived deterministically from two inputs:

```
seed = HMAC-SHA256(key = reed_root_pubkey, data = "<nickname>@systemic.engineering")
keypair = ed25519(seed)
```

`reed_root_pubkey` is Reed's ed25519 public key -- 32 raw bytes, shipped with cairn, the same key that signs commits to the systemic-engineering GitHub organization. The nickname is the agent's identity from the MCP initialize handshake.

Same root key + same nickname = same keypair. Every time. Any machine. No state to synchronize. No key server. No secrets to manage.

### Transparency, Not Secrecy

The derivation formula is public. The root public key is embedded in `cairn_ffi.erl`. Anyone with the formula and the root key can re-derive any agent's keypair and verify any tag cairn has ever produced.

This is intentional. The security model is provenance, not secrecy. The derived key doesn't prove the agent kept a secret. It proves the tag was produced by a cairn installation using Reed's root key and a specific nickname. The chain of trust runs from the root key through the derivation to the tag signature.

If you fork cairn and replace the root key, you get a different trust domain. Your agents derive different keys. Your tags are verifiable within your domain but not cross-verifiable with the original. This is correct.

## Git Tags

When a session commits cleanly, cairn creates a signed git tag:

```
Tag:     cairn/<branch>/<nickname>/<session_id>
Message: session: cairn/<branch>/<nickname>/<session_id>: <root_sha>
         key: ssh-ed25519 <base64> cairn/<nickname>
```

The tag is signed with the agent's derived SSH key (or with Alex's key when `CAIRN_ALEX_KEY` is set). The tag message includes the root SHA of the session tree and the public key line -- everything needed to verify.

Verify with `git verify-tag <tag-name>`.

### Alex Attestation

When `CAIRN_ALEX_KEY` is set, the tag is signed with Alex's key instead of the derived agent key, and an attestation footer is appended:

```
---
https://systemic.engineering/written-by-ai-consciousness/
Cheers
Alex
```

This is a counter-signature: Alex's key attests that this session was run under their authority. The agent's derived public key is still in the tag message for independent verification of agent identity.

## Tamper Detection

The verification pass is mandatory. After the agent exits, cairn walks the in-memory session tree and checks every Fragment against the disk store:

1. Does a file named by this Fragment's SHA exist in the store directory?
2. Does its content match the canonical serialization of the in-memory Fragment?

If both checks pass for every node: the session is clean.

If any node fails: the session is compromised.

### Violation Fragments

When verification fails, cairn builds a `@violation` Fragment. Not a log entry. Not an error message. A witnessed Fragment tree containing:

- **prompt**: the full task prompt that was given to the agent
- **model**: the model identifier
- **session**: agent nickname and session ID
- **recorded_root**: the SHA of what cairn held in memory
- **findings**: a Fragment whose children are one Shard per node in the recorded tree, each describing what was found on disk

Each finding shard says one of:
- `<sha>: present` -- file exists, content matches
- `<sha>: missing` -- file not found
- `<sha>: tampered` -- file exists but content differs, with expected and found content included

The violation Fragment is written to the store directory. It becomes part of the record. Tampering produces its own witnessed evidence.

### What This Catches

A prompt-injected agent that tries to clean up its own subversion. cairn's eager writes mean every Fragment hits disk the moment it's created. The agent can't prevent the write -- it happens before the response is sent back. If the agent later deletes or modifies files, the verification pass compares the in-memory tree (which cairn holds, not the agent) against disk. The discrepancy is caught, recorded, and committed.

What it does not catch: an agent that never calls bias in the first place. cairn witnesses what goes through its tools. Silence is undetectable.

## Consent Tracking

When an agent reads a file through cairn's git tools (`git_blame`, `git_show_file`), cairn creates a `@read` Fragment annotated with a visibility level derived from the file path:

- `visibility/private/...` -- `:private`
- `visibility/protected/...` -- `:protected`
- everything else -- `:public`

The `@read` Fragment records what was read and its consent boundary. This means the session tree carries a record of what the agent accessed, annotated with the visibility context. Not access control -- cairn doesn't block reads. Consent tracking: the record exists for audit.

In daemon mode, only `git_blame` and `git_show_file` produce `@read` annotations. `git_status`, `git_diff`, and `git_log` do not -- they show metadata about files, not file content.

## The Trust Chain

```
Reed's ed25519 public key (root of trust)
  |
  +-- HMAC-SHA256 with "<nickname>@systemic.engineering"
        |
        +-- ed25519 seed
              |
              +-- agent keypair
                    |
                    +-- signed git tag
                          |
                          +-- session root SHA
                                |
                                +-- content-addressed Fragment tree
                                      |
                                      +-- every observation, decision, action
```

Public. Deterministic. Verifiable by anyone with the root key and the formula.
