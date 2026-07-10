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

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || exit 0
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Statement-boundary prefix — see block-main-branch.sh for rationale.
_STMT_START='(^|[;&|]|\$\()[[:space:]]*'

# Block file viewers/editors opening .env files.
# The tool name must be at a statement boundary; the .env path follows as an argument.
# Handles unquoted, single-quoted, and double-quoted paths (e.g. cat ".env.local").
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(cat|less|head|tail|more|bat|zcat|nano|vim|nvim|vi|emacs|code|cursor|subl|open)[[:space:]]+[\"']?[^\"']*\.env"; then
  _grok_block "Blocked: reading .env files or dumping environment variables is not permitted. If a secret is needed for this task, ask the user to supply it directly." 
fi

# Block printenv at a statement boundary (with or without arguments).
if echo "$COMMAND" | grep -qE "${_STMT_START}printenv([[:space:]]|\$)"; then
  _grok_block "Blocked: reading .env files or dumping environment variables is not permitted. If a secret is needed for this task, ask the user to supply it directly." 
fi

# Block bare `env` used as a dump (no args, or piped/redirected).
# Must be at a statement boundary. Does NOT block `env VAR=value command`.
if echo "$COMMAND" | grep -qE "${_STMT_START}env[[:space:]]*(\$|[|>&])"; then
  _grok_block "Blocked: bare 'env' to dump environment variables is not permitted. If a secret is needed for this task, ask the user to supply it directly."
fi

# Block GitHub CLI auth token exposure.
# gh must be at a statement boundary.
if echo "$COMMAND" | grep -qE "${_STMT_START}gh[[:space:]]+auth[[:space:]]+token"; then
  _grok_block "Blocked: 'gh auth token' exposes the GitHub authentication token. If this token is needed for a task, ask the user to supply it directly."
fi

exit 0
