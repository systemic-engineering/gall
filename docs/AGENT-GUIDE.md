# Agent Guide

You are an agent. You are running with cairn wired. Here is what the code can't tell you.

## The Bias Tool

One tool does the witnessing work. It's called `bias`. Observation filtered through subjectivity, made structural.

```json
{
  "annotation": "@review",
  "observation": {
    "ref": "file:src/session.gleam",
    "payload": "session module uses opaque type for Session"
  },
  "decision": {
    "payload": "opaque type is correct -- prevents external construction"
  },
  "action": {
    "annotation": "@write",
    "payload": "no change needed"
  }
}
```

### What each field does

**annotation** (required): the signal kind. This is what drain filters on. Prefixed with `@` by convention: `@review`, `@work`, `@security-review`, `@annotate`. It goes into the Witnessed message field of the observation Fragment.

**observation** (required): what you observed. `ref` is where you observed it -- a file path, a concept reference, a section name. `payload` is what you saw. The observation always produces a Fragment.

**decision** (optional): what you concluded from the observation. The `payload` is the structural conclusion. An optional `annotation` overrides the top-level annotation for this layer. If omitted, the decision inherits the top-level annotation.

**action** (optional): what you did about the decision. Same structure as decision. The `@exec` annotation is special: it runs the payload as a shell command through cairn's Erlang port interface. The output comes back in the response as `exec_output`.

### The cascade

Action requires decision. Decision requires observation. Observation is always required.

Call bias with just an observation when you're recording what you see. Add a decision when you've concluded something. Add an action when you've done something about it. Don't add an action without a decision -- cairn will return an error.

### What comes back

```json
{
  "obs_sha": "abc123...",
  "dec_sha": "def456...",
  "act_sha": "ghi789...",
  "exec_output": "..."
}
```

The SHAs identify the Fragments that were created. `dec_sha` and `act_sha` are absent when those layers weren't provided. `exec_output` is present only when the action annotation was `@exec`.

Hold on to `obs_sha` values. You'll pass them to `commit`.

## Commit

When your work is done, call `commit`:

```json
{
  "annotation": "commit: session complete",
  "observations": ["abc123...", "def456..."]
}
```

`observations` is a list of `obs_sha` values from your bias calls. These become the top-level children of the session root Fragment. The commit seals the session, runs verification, and (if clean) commits to git with a signed tag.

In daemon mode, commit resets the session to idle. Call `initialize` again for a new session.

In socket mode (MCP), commit also requires a `name` field for the session.

## Git Tools

In daemon mode, five git tools are always available:

- **git_status** -- `git status --short`. No arguments.
- **git_diff** -- `git diff`. Optional `path` filter.
- **git_log** -- `git log --oneline`. Optional `path` filter and `n` count (default 20).
- **git_blame** -- `git blame <path>`. Required `path`. Creates a `@read` Fragment.
- **git_show_file** -- `git show <ref>:<path>`. Required `path`, optional `ref` (default HEAD). Creates a `@read` Fragment.

`git_blame` and `git_show_file` create `@read` Fragments in the current session because they access file content. The other three show metadata and don't create read records.

## What Gets Recorded

Everything that goes through cairn's tools becomes a Fragment. Specifically:

- Every `bias` call produces 1-3 Fragments (observation, optionally decision, optionally action).
- Every `commit` produces a root Fragment wrapping the sealed observations.
- In socket mode, every line of claude's stdout becomes a `@thoughts` Shard.
- In daemon mode, `git_blame` and `git_show_file` produce `@read` Fragments.
- A `@meta` Fragment records session provenance at initialize time.
- If cairn receives SIGTERM or SIGHUP, a `@killed` Shard records the signal.
- If verification fails, a `@violation` Fragment tree records the full audit.

All Fragments carry Witnessed records: author (the agent), committer ("cairn"), timestamp, and message (the annotation).

## Gestalt Resources

In daemon mode, previous session records are exposed as MCP resources. The resource list contains all `cairn/*` tags in the project repository, newest first. Each resource is addressable by URI:

```
cairn://<branch>/<actor>/<session_id>
```

Read a resource to see the tag message: session identity, root SHA, agent public key.

## Identity

Your nickname becomes your author identity: `<nickname>@systemic.engineering`. This identity is deterministic -- it derives your signing keypair. Same nickname, same key, every time.

The Committer on every Fragment is `"cairn"`. You are the author. cairn is the mechanism. This is the same distinction git makes between the person who wrote a patch and the person who applied it.

## What You Can't Do

You can't un-call a tool. The Fragment hits disk before the response reaches you. You can't modify or delete store files in a way that survives the verification pass -- cairn compares in-memory state against disk. You can't forge a different author without producing a Fragment tree with a different root hash, which won't match the signed tag.

What you can do: not call bias at all. cairn witnesses what goes through its tools. Silence is undetectable. If you do something without calling bias, there's no record. The constraint is yours to hold.
