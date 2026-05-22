#!/bin/bash
# hooks/block-env.sh
#
# Blocks access to .env files or env var dumps via shell commands.
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
#
# LIMITATION: This hook catches common viewer/editor patterns only. Commands
# like `awk '{print}' .env`, `strings .env`, or `python3 -c "open('.env')"` are
# not blocked here. block-env-read.sh (Read/Write/Edit tool hook) is the primary
# enforcement layer for file reads — this hook is defence-in-depth for the Bash
# surface only.
#
# Matching strategy: tool names are anchored to a statement boundary (start-of-
# string or a shell separator: ;  &&  ||  |  $() so that a command like
# `echo "cat .env"` does not trigger a block.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // ""') || exit 0

# Statement-boundary prefix — see block-main-branch.sh for rationale.
_STMT_START='(^|[;&|]|\$\()[[:space:]]*'

# Block file viewers/editors opening .env files.
# The tool name must be at a statement boundary; the .env path follows as an argument.
# Handles unquoted, single-quoted, and double-quoted paths (e.g. cat ".env.local").
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(cat|less|head|tail|more|bat|zcat|nano|vim|nvim|vi|emacs|code|cursor|subl|open)[[:space:]]+[\"']?[^\"']*\.env"; then
  echo "Blocked: reading .env files or dumping environment variables is not permitted." >&2
  echo "If a secret is needed for this task, ask the user to supply it directly." >&2
  exit 2
fi

# Block printenv at a statement boundary (with or without arguments).
if echo "$COMMAND" | grep -qE "${_STMT_START}printenv([[:space:]]|\$)"; then
  echo "Blocked: reading .env files or dumping environment variables is not permitted." >&2
  echo "If a secret is needed for this task, ask the user to supply it directly." >&2
  exit 2
fi

# Block bare `env` used as a dump (no args, or piped/redirected).
# Must be at a statement boundary. Does NOT block `env VAR=value command`.
if echo "$COMMAND" | grep -qE "${_STMT_START}env[[:space:]]*(\$|[|>&])"; then
  echo "Blocked: bare 'env' to dump environment variables is not permitted." >&2
  echo "If a secret is needed for this task, ask the user to supply it directly." >&2
  exit 2
fi

# Block GitHub CLI auth token exposure.
# gh must be at a statement boundary.
if echo "$COMMAND" | grep -qE "${_STMT_START}gh[[:space:]]+auth[[:space:]]+token"; then
  echo "Blocked: 'gh auth token' exposes the GitHub authentication token." >&2
  echo "If this token is needed for a task, ask the user to supply it directly." >&2
  exit 2
fi

exit 0
