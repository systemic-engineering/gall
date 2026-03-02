# What Cairn Is

Cairn witnesses AI agent work. It makes that work tamper-proof. It stores the record in git.

The name: stones stacked to mark "I was here." Wayfinding, not surveillance. A cairn doesn't watch you. It marks that someone passed through. You find it on the trail and you know: someone was here before me. They left a record.

That's what this library does for agent sessions. Every observation, decision, and action an agent takes during a session becomes a content-addressed Fragment node. The complete session tree is written to disk eagerly, verified on exit, committed to git, and signed with a deterministic SSH key. If the agent -- or anything else -- tampers with the record, the verification pass catches it, and the tampering itself becomes a witnessed Fragment.

## Two Modes

### Socket mode

cairn spawns claude. Not the other way around.

1. Start a unix socket MCP server.
2. Write an MCP config pointing at the socket.
3. Spawn claude with that config -- claude calls cairn's tools.
4. Capture claude's stdout line by line as thought Shards, written to disk the moment they arrive.
5. Handle MCP tool calls (bias, commit). Each Fragment written to disk immediately.
6. After claude exits: verify every Fragment in the session tree exists on disk, content-identical to what's in memory.
7. If clean: commit the session tree to `.cairn/` and tag it.

The orchestrator is `cairn.gleam`. It owns the event loop, the socket I/O, and the disk writes. The MCP protocol handler (`cairn/mcp.gleam`) is transport-agnostic -- it takes JSON, returns JSON, and never touches the filesystem.

### Daemon mode

A long-lived stdio MCP server. Installed into Claude Code (or any MCP client) as a persistent server that survives across prompts.

Two capability layers:

- **Bias witnessing** (bias, commit) -- session-scoped. Call `initialize` to start a new session. `commit` seals the session, runs verification, commits to git, resets to idle.
- **Git tools** (git_status, git_diff, git_log, git_blame, git_show_file) -- always available, no session required.

Daemon mode also serves **gestalt resources**: previous session records exposed as MCP resources, addressable by URI (`cairn://<branch>/<actor>/<timestamp>`).

The daemon is `cairn/daemon.gleam`. Run it with `gleam run --module cairn/daemon` from the project directory.

## Session Lifecycle

```
initialize --> observe/decide/act --> commit --> verify --> git tag
```

### Initialize

The agent connects. Its nickname becomes `Author("<nickname>@systemic.engineering")` on every Fragment in the session. In socket mode, the nickname comes from the spawned claude process. In daemon mode, it comes from `clientInfo.name` in the MCP initialize request, falling back to `CAIRN_NICKNAME` env, falling back to `"agent"`.

A `@meta` Fragment records the session provenance: author, client version, protocol version. Written to disk immediately.

### Observe / Decide / Act

The agent calls the `bias` tool. One call can produce up to three Fragment layers, built bottom-up:

```
Observation                        <-- always required
  Decision                         <-- optional (requires observation)
    Action                         <-- optional (requires decision)
```

This is the ADO cascade. Action requires decision. Decision requires observation. Observation is always required. You cannot act without deciding. You cannot decide without observing. But you can observe without deciding or acting.

Each layer becomes a Fragment node. Actions are Shards (terminal). Decisions are Fragments wrapping their actions. Observations are Fragments wrapping their decisions. The tree structure encodes the causal chain: walking an observation gives you the full chain of reasoning.

### Commit

The agent calls `commit` with the observation SHAs to seal. Commit builds a root Fragment wrapping the observations, writes it to disk, and runs the verification pass.

### Verify

Walk the in-memory session tree from root. For each Fragment, check that a file named by its SHA exists in the store directory and that its content matches the canonical serialization. If all match: the session is clean. If any are missing or tampered: the session is compromised.

### Git Tag

If verification passes, cairn commits the `.cairn/` session directory into the project's git repository. It creates a signed tag at `cairn/<branch>/<nickname>/<session_id>`. The tag message carries the root SHA and the agent's public key. The signature is produced with a deterministically derived SSH key -- same agent, same key, every time.

If verification fails, cairn builds a `@violation` Fragment containing the full audit trail: prompt, model, session identity, recorded root SHA, and a findings tree where each node describes what was found on disk (present, missing, or tampered with expected vs. actual content). The violation is itself a witnessed Fragment. Tampering produces its own record.

## Eager Writes

Every Fragment is written to disk the moment it's created. Not batched. Not deferred. The store accumulates during the session, not after.

This is the core security property. An agent can call tools but can't un-call them. The disk record exists during the session. A prompt-injected agent that deletes or modifies files will be caught by the verification pass on exit. A SIGKILL -- the one signal that can't be caught -- loses at most the current in-flight Fragment, because everything before it is already on disk.

cairn catches SIGTERM and SIGHUP. On either signal, it writes a `@killed` shard, records an exit status, and shuts down cleanly. The eager writes mean the disk is current. The verification pass can still run.

## The ADO Cascade

The bias tool enforces a structural constraint: action requires decision requires observation.

This is not arbitrary. It encodes a claim about the relationship between seeing, concluding, and doing. If you act, you must have decided. If you decide, you must have observed. You can observe without either -- observation without consequence is valid. Action without observation is not.

The cascade is enforced at the protocol level. Calling bias with an action but no decision returns an error. The Fragment tree is not built. The agent must structure its work as observe-decide-act or leave layers empty from the bottom up.

In daemon mode, the `@exec` annotation on an action triggers shell execution: cairn runs the command via the Erlang port interface, captures stdout and stderr, and includes the output in the bias response. The action Fragment records what was run. The execution output is part of the response, not the Fragment -- the Fragment records intent, the response carries result.

## Storage Layout

```
.cairn/
  actors/
    <nickname>/
      worktrees/
        <branch>/
          <session_id>/
            store/          <-- SHA-named Fragment files
            EXIT            <-- exit code + status
            mcp.sock        <-- unix socket (socket mode only)
            mcp.json        <-- MCP config for claude (socket mode only)
```

`.cairn/` lives inside the project directory. No nested git repo. The project's own git tracks `.cairn/` as plain files. Session tags live in the project's tag namespace.

## Config

Session configuration is stored as a git tag (`config`) in the project repository.

```
sync = true
sync.remote = garden@systemic.engineering
```

- `sync` -- send a patch after each witnessed session (default: false).
- `sync.remote` -- patch destination. If the value contains `@`, treated as an email recipient (git send-email). Otherwise treated as a git remote URL (git push).

## Environment Variables

- `CAIRN_WORKTREE` -- project working directory. Overrides PWD. Set by cairn when spawning an agent into a worktree.
- `CAIRN_BRANCH` -- branch name. Overrides `git rev-parse --abbrev-ref HEAD`. Set by cairn when spawning.
- `CAIRN_ALEX_KEY` -- path to Alex's SSH signing key. When set, tags carry the attestation footer and are signed with this key instead of the derived agent key.
- `CAIRN_NICKNAME` -- agent nickname (daemon mode fallback when `clientInfo.name` is absent).
