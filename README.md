# cairn

Tamper-proof witnessed AI agent work. Stones stacked to mark "I was here."

cairn captures the complete lifecycle of AI agent sessions through content-addressed Fragment trees (built on [fragmentation](https://hex.pm/packages/fragmentation)), with eager writes, deterministic key derivation, and mandatory verification.

Two modes:

- **Socket mode** -- cairn spawns claude, captures stdout as thought Shards, handles MCP tool calls, verifies on exit, commits to git.
- **Daemon mode** -- long-lived stdio MCP server installed into Claude Code. Bias witnessing + git tools + gestalt resources.

## Documentation

Read order: [docs/INDEX.md](docs/INDEX.md)

1. [What Cairn Is](docs/WHAT-CAIRN-IS.md) -- the concept, the two modes, the session lifecycle.
2. [Witnessed](docs/WITNESSED.md) -- trust model, key derivation, tamper detection.
3. [Modules](docs/MODULES.md) -- how the nine modules compose.
4. [Agent Guide](docs/AGENT-GUIDE.md) -- what agents need to know.

## Run

```sh
# Daemon mode (stdio MCP server)
gleam run --module cairn/daemon

# Tests
gleam test
```

## Install

```sh
gleam add cairn@1
```

```gleam
import cairn
import cairn/daemon
import cairn/session
```

## Licence

Apache-2.0
