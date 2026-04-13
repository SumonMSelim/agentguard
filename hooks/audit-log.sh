#!/bin/bash
# hooks/audit-log.sh
#
# PostToolUse audit log — appends one line per tool call to the agent's audit.log.
# Shared hook — used by both Claude (→ ~/.claude/audit.log) and Kiro (→ ~/.kiro/audit.log).
#
# Provides a forensic record that survives hook failures and helps detect
# unexpected behaviour or bypasses. Each entry records the UTC timestamp,
# tool name, and up to 200 characters of the relevant input (command, path,
# or description).
#
# Logging failures are silenced — they must never block tool execution.
# Exit 0 always.

INPUT=$(cat)

# Derive the log path from this script's own location so the hook always writes
# to the right agent's directory regardless of which other agents are installed:
#   ~/.claude/hooks/audit-log.sh  →  ~/.claude/audit.log
#   ~/.kiro/hooks/audit-log.sh    →  ~/.kiro/audit.log
LOG="$(cd "$(dirname "$0")/.." && pwd)/audit.log"

ENTRY=$(echo "$INPUT" | jq -r '
  (.tool_name // "unknown") as $tool |
  (.tool_input.command // .tool_input.file_path // .tool_input.path // (.tool_input.operations // [] | first | .path // "") // .tool_input.description // "") as $detail |
  "\(now | strftime("%Y-%m-%dT%H:%M:%SZ")) tool=\($tool) \($detail | .[0:200])"
' 2>/dev/null)

if [[ -n "$ENTRY" ]]; then
  echo "$ENTRY" >> "$LOG" 2>/dev/null || true
fi

exit 0
