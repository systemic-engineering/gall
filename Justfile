# cairn dev tooling
#
# Build, lint, test, format. Not the MCP API.
# Usage: just --justfile Justfile.dev <recipe>

check: lint test format-check

lint:
    nix develop -c cargo clippy --manifest-path rust/Cargo.toml -- -D warnings

test:
    nix develop -c cargo test --manifest-path rust/Cargo.toml

format-check:
    nix develop -c cargo fmt --manifest-path rust/Cargo.toml -- --check

pre-commit: check
pre-push: check

format:
    nix develop -c cargo fmt --manifest-path rust/Cargo.toml
