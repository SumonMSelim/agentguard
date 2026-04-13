#!/bin/bash
# hooks/block-system-installs.sh
#
# Blocks system-level package manager invocations.
# The agent should use Docker instead, or ask the user for permission first.
#
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
# Catches: apt, apt-get, brew, yum, dnf, pacman, apk, global npm/yarn/pnpm,
# and sudo pip installs.
#
# Note: plain `pip install` without sudo (outside a virtualenv) is NOT blocked
# here to avoid false positives — the instruction file covers that case.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""') || exit 0

# Block system package managers.
# No ^ anchor — chained commands like `echo done && brew install foo` must also be caught.
if echo "$COMMAND" | grep -qE \
  '\b(sudo\s+)?(apt|apt-get|yum|dnf|pacman|brew|apk)\s+(install|add)\b'; then
  echo "Blocked: system package installation is not permitted." >&2
  echo "Use Docker instead, or ask the user for explicit permission first." >&2
  exit 2
fi

# Block global JS package installs
if echo "$COMMAND" | grep -qE \
  '\bnpm\s+(install|i)\s+(-g|--global)\b|\byarn\s+global\s+add\b|\bpnpm\s+(add|install)\s+(-g|--global)\b'; then
  echo "Blocked: global npm/yarn/pnpm installs are not permitted." >&2
  echo "Use a local install inside Docker or the project instead." >&2
  exit 2
fi

# Block sudo pip installs (no ^ anchor — catches chained commands)
if echo "$COMMAND" | grep -qE '\bsudo\s+pip3?\s+install\b'; then
  echo "Blocked: sudo pip install is not permitted." >&2
  echo "Use Docker or a virtualenv instead." >&2
  exit 2
fi

exit 0
