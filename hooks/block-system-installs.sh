#!/bin/bash
# hooks/block-system-installs.sh
#
# Blocks system-level package manager invocations.
# The agent should use Docker instead, or ask the user for permission first.
#
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
# Catches: apt, apt-get, brew, yum, dnf, pacman, apk, global npm/yarn/pnpm,
# sudo pip installs, and plain pip installs outside an active virtualenv.
#
# Matching strategy: package manager names are anchored to a statement boundary
# (start-of-string or a shell separator: ;  &&  ||  |  $() so that a command
# like `echo "brew install foo"` does not trigger a block.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || exit 0
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Statement-boundary prefix — see block-main-branch.sh for rationale.
# sudo is included as an optional prefix since package managers are often invoked
# via sudo and the sudo itself appears at the statement boundary.
_STMT_START='(^|[;&|]|\$\()[[:space:]]*(sudo[[:space:]]+)?'

# Block system package managers.
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(apt|apt-get|yum|dnf|pacman|brew|apk)[[:space:]]+(install|add)"; then
  _grok_block "Blocked: system package installation is not permitted. Use Docker instead, or ask the user for explicit permission first."
fi

# Block global JS package installs.
# Note: `npm install typescript --global` (flag after package name) is not blocked —
# the flag must precede the package name to match. This is an accepted gap; AI agents
# consistently place flags before arguments, and blocking all `npm install` with any
# --global anywhere would risk false positives on package names containing "global".
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}npm[[:space:]]+(install|i)[[:space:]]+(-g|--global)"; then
  _grok_block "Blocked: global npm/yarn/pnpm installs are not permitted. Use a local install inside Docker or the project instead."
fi
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}yarn[[:space:]]+global[[:space:]]+add"; then
  _grok_block "Blocked: global npm/yarn/pnpm installs are not permitted. Use a local install inside Docker or the project instead."
fi
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}pnpm[[:space:]]+(add|install)[[:space:]]+(-g|--global)"; then
  _grok_block "Blocked: global npm/yarn/pnpm installs are not permitted. Use a local install inside Docker or the project instead."
fi

# Block sudo pip installs.
# sudo is already part of _STMT_START so we match: (boundary) sudo pip install
if echo "$COMMAND" | grep -qE \
  "(^|[;&|]|\$\()[[:space:]]*sudo[[:space:]]+pip3?[[:space:]]+install"; then
  _grok_block "Blocked: sudo pip install is not permitted. Use Docker or a virtualenv instead."
fi

# Block plain pip install outside an active virtualenv.
# VIRTUAL_ENV is set by virtualenv/venv activate scripts. If it is unset or empty,
# pip install would modify the system or user Python environment.
# Does NOT block: sudo pip (already caught above), pip show/list/freeze/etc.
#
# Known gaps (out of scope for this hook):
#   - conda envs: `conda activate` sets CONDA_DEFAULT_ENV but not VIRTUAL_ENV,
#     so pip installs inside a conda env are not blocked here. The instruction
#     file covers this case.
#   - `python -m pip install`: the pattern only matches the `pip`/`pip3` binary
#     invocation, not the module form. Blocking `python -m ...` would produce
#     too many false positives for other modules.
if echo "$COMMAND" | grep -qE \
  "(^|[;&|]|\$\()[[:space:]]*pip3?[[:space:]]+install"; then
  if [[ -z "${VIRTUAL_ENV:-}" ]]; then
    _grok_block "Blocked: pip install outside a virtualenv is not permitted. Activate a virtualenv first, or use Docker."
  fi
fi

exit 0
