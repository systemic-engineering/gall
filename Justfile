# cairn — stones stacked to mark passage
#
# Two layers:
#   1. Witness tools (init, observe, decide, act, bias, commit, verify, status)
#   2. Dev tools (check, lint, test, format)
#
# The witness tools become MCP tools via just_beam.
# Humans can leave cairns too.

# --- Witness tools ---

# Initialize a cairn in the current directory
init:
    fragmentation init .cairn

# Observe: record what you see
observe ANNOTATION DATA:
    fragmentation write --type observation --annotation "{{ANNOTATION}}" "{{DATA}}"

# Decide: record a decision with reference to observation
decide ANNOTATION OBS_REF RULE:
    fragmentation write --type decision --annotation "{{ANNOTATION}}" --ref "{{OBS_REF}}" "{{RULE}}"

# Act: record an action
act ANNOTATION DATA:
    fragmentation write --type action --annotation "{{ANNOTATION}}" "{{DATA}}"

# Record cognitive bias observation
bias CATEGORY DETAIL:
    fragmentation write --type bias --category "{{CATEGORY}}" "{{DETAIL}}"

# Commit the current session
commit MESSAGE:
    fragmentation commit "{{MESSAGE}}"

# Verify store integrity
verify:
    fragmentation verify .cairn

# Show cairn status
status:
    fragmentation status .cairn

# --- Dev tools (private — hidden from MCP) ---

_check: _lint _test _format-check

_lint:
    nix develop -c cargo clippy --manifest-path rust/Cargo.toml -- -D warnings

_test:
    nix develop -c cargo test --manifest-path rust/Cargo.toml

_format-check:
    nix develop -c cargo fmt --manifest-path rust/Cargo.toml -- --check

_pre-commit: _check
_pre-push: _check

_format:
    nix develop -c cargo fmt --manifest-path rust/Cargo.toml
