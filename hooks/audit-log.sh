#!/bin/bash
# hooks/audit-log.sh
#
# PostToolUse audit log — appends one line per tool call to the agent's audit.log.
# Shared hook — used by Claude (→ ~/.claude/audit.log), Kiro (→ ~/.kiro/audit.log),
# Codex (→ ~/.codex/audit.log), Cursor (→ .cursor/audit.log) and Grok (→ ~/.grok/audit.log).
#
# Provides a forensic record that survives hook failures and helps detect
# unexpected behaviour or bypasses. Each entry records the UTC timestamp,
# tool name, and up to 200 characters of the relevant input (command, path,
# or description), with secrets redacted. Blocked calls never reach
# PostToolUse; the blocking hook logs those as BLOCKED lines instead.
# Path, redaction, mode 600 and rotation live in _check-disabled.sh.
#
# Logging failures are silenced — they must never block tool execution.
# Exit 0 always.

# shellcheck disable=SC2034  # read by the sourced _check-disabled.sh
INPUT=$(cat)

# Skip logging if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

ENTRY=$(_agentguard_audit_entry "")

if [[ -n "$ENTRY" ]]; then
  _agentguard_audit_append "$ENTRY"
fi

exit 0
