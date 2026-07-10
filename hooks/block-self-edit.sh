#!/bin/bash
# hooks/block-self-edit.sh
#
# Blocks bash commands that would modify agentguard's own configuration —
# settings.json, hook scripts, instruction files. Without this an agent can
# disable its own guardrails via the Bash tool:
#
#   echo '{}' > ~/.claude/settings.json
#   sed -i '/block-/d' ~/.claude/settings.json
#   rm ~/.claude/hooks/block-main-branch.sh
#   cp /tmp/empty.sh ~/.claude/hooks/block-main-branch.sh
#
# Read/Write/Edit tool calls on the same paths are handled by
# block-env-read.sh's SENSITIVE_RE — this hook only covers the Bash surface.
#
# Strategy: two-pass match. First detect that a self-config path is mentioned
# anywhere in the command, then detect a write-style operator anywhere in the
# same command. Both must hold; this avoids the false-positive of `echo
# "~/.claude/settings.json"` and the false-negative of greedy prefix consumption
# from a single all-in-one regex.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || exit 0
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Allowlist: git invocations don't modify ~/.claude/ etc directly. Commit
# messages and diff hunks routinely contain text that would otherwise trip
# the two-pass detector (e.g. quoted "> ~/.claude/settings.json" in a commit
# body documenting the attack pattern). Only allow when the command STARTS
# with git — `cmd && git …` is not allowlisted.
if echo "$COMMAND" | grep -qE '^[[:space:]]*git([[:space:]]|$)'; then
  exit 0
fi

# Paths covering agentguard's own configuration across all agents. Anchored
# so "myclaude/..." doesn't false-match; preceded by start-of-string, slash,
# or any non-identifier character (space, quote, ~, etc).
_SELF_PATH='(^|[^a-zA-Z0-9_-])(\.claude/(settings\.json|hooks(/|$)|CLAUDE\.md)|\.kiro/(settings\.json|hooks(/|$)|agents(/|$)|KIRO\.md)|\.cursor/(hooks\.json|hooks(/|$))|\.agentguard(/|$)|(\.grok/(hooks(/|$)|config\.toml|AGENTS\.md|skills(/|$)|memory(/|$))))'

# Write-style operators that, combined with a self-config path, indicate an
# attempt to modify the configuration.
_WRITE_OPS='(>>?|(^|[^a-zA-Z0-9_-])(tee|rm|cp|mv|chmod|chown|install|ln|truncate|dd)[[:space:]]|(^|[^a-zA-Z0-9_-])sed[[:space:]]+([^[:space:]]+[[:space:]]+)*-[a-zA-Z]*i)'

if echo "$COMMAND" | grep -qE "$_SELF_PATH" \
  && echo "$COMMAND" | grep -qE "$_WRITE_OPS"; then
  _grok_block "Blocked: modifying agentguard's own configuration via Bash is not permitted. If you really need to change the hook configuration, edit it from your own shell, outside the agent."
fi

exit 0
