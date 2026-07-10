#!/bin/bash
# hooks/block-env-read.sh
#
# Blocks Read, Write, Edit, fs_read, and fs_write tools on sensitive file paths.
# Shared hook — used by both Claude (Read/Write/Edit) and Kiro (fs_read/fs_write).
#
# Covers: .env files, direnv (.envrc), private key files, credential stores.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
# Claude:  .tool_input.path (Read/Write), .tool_input.file_path (Edit), .tool_input.file_path (MultiEdit)
# Kiro:    .tool_input.path (fs_write),   .tool_input.operations[].path (fs_read)
# Grok:    .toolInput.path / .toolInput.target_file (read_file), .toolInput.file_path (search_replace)
# Collect all candidate paths; trim whitespace via sed (xargs would split paths with spaces).
PATHS=$(echo "$INPUT" | jq -r '
  (.file_path // ""),
  (.tool_input.file_path // ""),
  (.tool_input.path // ""),
  (.toolInput.file_path // ""),
  (.toolInput.path // ""),
  (.toolInput.target_file // ""),
  (.tool_input.operations // [] | .[].path // ""),
  (.toolInput.operations // [] | .[].path // ""),
  (.tool_input.edits // [] | .[].file_path // "")
' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

SENSITIVE_RE='(^|/)\.env(\.|$)|(^|/)\.env$|\.envrc$|secrets/|\.aws/|\.ssh/|credentials|\.netrc$|\.(pem|key|p12|pfx)$|/\.agentguard($|/)|/\.claude/(settings\.json|hooks/|CLAUDE\.md$)|/\.kiro/(settings\.json|hooks/|agents/|KIRO\.md$)|(^|/)\.cursor/(hooks\.json$|hooks/)|/\.grok/(hooks/|config\.toml|AGENTS\.md$|skills/|memory/)|(^|/)\.grok/(hooks/|config\.toml|AGENTS\.md$)'

while IFS= read -r FILE; do
  if echo "$FILE" | grep -qE "$SENSITIVE_RE"; then
    _grok_block "Blocked: reading sensitive file '$FILE' is not permitted globally. If a value from this file is needed, ask the user to supply it directly."
  fi
done <<< "$PATHS"

exit 0
