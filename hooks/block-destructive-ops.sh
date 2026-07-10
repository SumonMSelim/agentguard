#!/bin/bash
# hooks/block-destructive-ops.sh
#
# Blocks shell patterns that can cause catastrophic or irreversible damage:
#   - rm targeting filesystem root or bare home directory
#   - pipe-to-shell (curl|bash, wget|sh, etc.) — supply chain risk
#
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
# Note: general `rm -rf <path>` is NOT blocked — legitimate uses like
# `rm -rf node_modules` or `rm -rf ./dist` are too common to intercept.
# Only anchored, catastrophic targets are blocked here.
#
# Matching strategy: rm, curl, and wget are anchored to a statement boundary
# (start-of-string or a shell separator: ;  &&  ||  |  $() so that a command
# like `echo "rm -rf /"` does not trigger a block.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || exit 0
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Statement-boundary prefix — see block-main-branch.sh for rationale.
_STMT_START='(^|[;&|]|\$\()[[:space:]]*(sudo[[:space:]]+)?'

# Block rm on filesystem root or bare home directory.
# rm must be at a statement boundary; the catastrophic path follows as an argument.
# Matches: rm /   rm /*   rm -rf /   rm -rf ~   rm -rf ~/   rm -rf ~/*
#          rm $HOME   rm $HOME/   rm $HOME/*
# The path separator [[:space:]] before the target handles both "rm /" (no flags)
# and "rm -rf /" (flags present). ([[:space:]]|$) after ensures we match the full
# argument and don't fire on /var/log etc.
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}rm[[:space:]]([^[:space:]]+[[:space:]]+)*(/\*?|~/?\*?|\$HOME/?\*?)([[:space:]]|\$)"; then
  _grok_block "Blocked: rm on root or home directory is not permitted. If you need to remove specific files, use an explicit path."
fi

# Block pipe-to-shell patterns (supply chain risk).
# curl/wget must be at a statement boundary.
# Catches: curl url | bash, wget -O- url | sh, curl url | sudo bash, etc.
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|fish|dash|ash|ksh)([[:space:]]|\$)"; then
  _grok_block "Blocked: pipe-to-shell (curl|bash, wget|sh, etc.) is not permitted. Download the script first, inspect it, then run it explicitly."
fi

exit 0
