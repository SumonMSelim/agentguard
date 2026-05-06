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

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // ""') || exit 0

# Statement-boundary prefix — see block-main-branch.sh for rationale.
# sudo is included as an optional prefix since package managers are often invoked
# via sudo and the sudo itself appears at the statement boundary.
_STMT_START='(^|[;&|]|\$\()[[:space:]]*(sudo[[:space:]]+)?'

# Block system package managers.
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(apt|apt-get|yum|dnf|pacman|brew|apk)[[:space:]]+(install|add)"; then
  echo "Blocked: system package installation is not permitted." >&2
  echo "Use Docker instead, or ask the user for explicit permission first." >&2
  exit 2
fi

# Block global JS package installs.
# Note: `npm install typescript --global` (flag after package name) is not blocked —
# the flag must precede the package name to match. This is an accepted gap; AI agents
# consistently place flags before arguments, and blocking all `npm install` with any
# --global anywhere would risk false positives on package names containing "global".
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}npm[[:space:]]+(install|i)[[:space:]]+(-g|--global)"; then
  echo "Blocked: global npm/yarn/pnpm installs are not permitted." >&2
  echo "Use a local install inside Docker or the project instead." >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}yarn[[:space:]]+global[[:space:]]+add"; then
  echo "Blocked: global npm/yarn/pnpm installs are not permitted." >&2
  echo "Use a local install inside Docker or the project instead." >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}pnpm[[:space:]]+(add|install)[[:space:]]+(-g|--global)"; then
  echo "Blocked: global npm/yarn/pnpm installs are not permitted." >&2
  echo "Use a local install inside Docker or the project instead." >&2
  exit 2
fi

# Block sudo pip installs.
# sudo is already part of _STMT_START so we match: (boundary) sudo pip install
if echo "$COMMAND" | grep -qE \
  "(^|[;&|]|\$\()[[:space:]]*sudo[[:space:]]+pip3?[[:space:]]+install"; then
  echo "Blocked: sudo pip install is not permitted." >&2
  echo "Use Docker or a virtualenv instead." >&2
  exit 2
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
    echo "Blocked: pip install outside a virtualenv is not permitted." >&2
    echo "Activate a virtualenv first, or use Docker." >&2
    exit 2
  fi
fi

exit 0
