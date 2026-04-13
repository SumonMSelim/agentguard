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
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""') || exit 0

# Block rm on filesystem root or bare home directory.
# Matches: rm ... /   rm ... /*   rm ... ~   rm ... ~/   rm ... ~/*
#          rm ... $HOME   rm ... $HOME/   rm ... $HOME/*
# The (\s|$) after the path ensures we match the full argument, not a prefix
# (e.g. /var/log would not match because 'v' follows the /).
if echo "$COMMAND" | grep -qE \
  'rm\b.*(\s|^)(/\*?|~/?\*?|\$HOME/?\*?)(\s|$)'; then
  echo "Blocked: rm on root or home directory is not permitted." >&2
  echo "If you need to remove specific files, use an explicit path." >&2
  exit 2
fi

# Block pipe-to-shell patterns (supply chain risk).
# Catches: curl url | bash, wget -O- url | sh, curl url | sudo bash, etc.
if echo "$COMMAND" | grep -qE \
  '(curl|wget)\s+.*\|\s*(sudo\s+)?(bash|sh|zsh|fish|dash|ash|ksh)\b'; then
  echo "Blocked: pipe-to-shell (curl|bash, wget|sh, etc.) is not permitted." >&2
  echo "Download the script first, inspect it, then run it explicitly." >&2
  exit 2
fi

exit 0
