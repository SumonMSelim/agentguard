#!/bin/bash
# hooks/block-env-read.sh
#
# Blocks Read, Write, Edit, fs_read, and fs_write tools on sensitive file paths.
# Shared hook — used by both Claude (Read/Write/Edit) and Kiro (fs_read/fs_write).
#
# Covers: .env files, direnv (.envrc), private key files, credential stores.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)
# Claude:  .tool_input.path (Read/Write), .tool_input.file_path (Edit)
# Kiro:    .tool_input.path (fs_write),   .tool_input.operations[].path (fs_read)
# Collect all candidate paths; trim whitespace via sed (xargs would split paths with spaces).
PATHS=$(echo "$INPUT" | jq -r '
  (.tool_input.file_path // ""),
  (.tool_input.path // ""),
  (.tool_input.operations // [] | .[].path // "")
' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)

SENSITIVE_RE='(^|/)\.env(\.|$)|(^|/)\.env$|\.envrc$|secrets/|\.aws/|\.ssh/|credentials|\.netrc$|\.(pem|key|p12|pfx)$'

while IFS= read -r FILE; do
  if echo "$FILE" | grep -qE "$SENSITIVE_RE"; then
    echo "Blocked: reading sensitive file '$FILE' is not permitted globally." >&2
    echo "If a value from this file is needed, ask the user to supply it directly." >&2
    exit 2
  fi
done <<< "$PATHS"

exit 0
