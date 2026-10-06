#!/bin/bash
# hooks/_check-disabled.sh
#
# Sourced (NOT executed) by every guardrail hook, after the hook has read its
# payload into INPUT. If the agent's directory is in the agentguard disabled
# list, exits 0 — short-circuiting the host hook so all its checks are skipped.
#
# The agent's directory is the payload's .cwd (Claude Code, Codex and Cursor
# send it; it follows the agent's `cd`), else the hook's own working directory.
#
# The disabled list lives at ~/.agentguard/disabled-dirs, one absolute path
# per line. A directory matches if it equals an entry, or is below one
# (ancestor disables descendants). Trailing slashes are ignored, so `/`
# disables everything. Blank lines and `#` comments ignored.
#
# Override the path with AGENTGUARD_DISABLED_DIRS_FILE (test seam).
#
# Disabling is gated to the user via `agentguard disable` (which refuses to
# run inside Claude Code). Re-enabling is open — restoring guardrails can't
# hurt.
#
# Cursor output contract (cursor.com/docs/agent/hooks, checked 2026-10-06).
# Each hook pastes _is_cursor/_allow/_grok_block to implement it:
#   - Input: every hook gets conversation_id, generation_id, hook_event_name,
#     workspace_roots, ... at top level. beforeShellExecution adds flat
#     "command"/"cwd"; beforeReadFile adds flat "file_path"/"content". So a
#     Cursor permission payload = top-level command or file_path, and no
#     tool_input (Claude/Kiro) or toolInput (Grok). preToolUse and
#     beforeMCPExecution carry tool_name/tool_input like Claude, so they are
#     told apart by hook_event_name (Claude and Codex send "PreToolUse").
#     beforeMCPExecution tool_input is the MCP params as a JSON string.
#   - Output: {"permission":"allow"|"deny","user_message":..,"agent_message":..}
#     (beforeReadFile: permission + user_message only). Snake_case.
#   - "Exit code 0 - Hook succeeded, use the JSON output. Exit code 2 - Block
#     the action (equivalent to returning permission: "deny")."
#   - "Invalid JSON or a response that doesn't match the hook's schema blocks
#     the action." Empty stdout on exit 0 is therefore printed as allow JSON.
#   - postToolUse output is optional ("no output is required"); audit-log.sh
#     prints nothing.

# Audit log, shared by audit-log.sh (one line per tool call) and every block
# path (_agentguard_log_block writes a BLOCKED line). The log sits next to the
# hooks dir: ~/.claude/hooks/x.sh -> ~/.claude/audit.log. AGENTGUARD_AUDIT_LOG
# overrides the path (test seam). The file is mode 600; above 1 MB it moves to
# audit.log.1 (one generation kept). Secrets are redacted before writing.
# Logging never fails the hook: all errors are dropped and nothing is printed.
_agentguard_audit_append() {
  (
    umask 077
    log="${AGENTGUARD_AUDIT_LOG:-$(cd "$(dirname "$0")/.." && pwd)/audit.log}"
    if [[ -f "$log" ]] && (( $(wc -c < "$log") > 1048576 )); then mv -f "$log" "$log.1"; fi
    printf '%s\n' "$1" >> "$log" && chmod 600 "$log"
  ) >/dev/null 2>&1 || true
}
# Log line for the payload in $INPUT: "<UTC time> <$1>tool=<name> <detail>".
# Redacts token/key/secret/password=..., Bearer ... and Authorization: ...
# before truncating the detail to 200 characters.
_agentguard_audit_entry() {
  echo "${INPUT:-}" | jq -r --arg pfx "$1" '
    (.tool_name // .tool // .toolName // "unknown") as $tool |
    (
      .command //
      .file_path //
      .tool_input.command //
      .tool_input.file_path //
      .tool_input.path //
      .toolInput.command //
      .toolInput.file_path //
      .toolInput.path //
      .toolInput.target_file //
      (.tool_input.operations // [] | first | .path // "") //
      (.toolInput.operations // [] | first | .path // "") //
      .tool_input.description //
      ""
    ) as $detail |
    ($detail | tostring
      | gsub("(?<k>(token|key|secret|password)=)\\S+"; "\(.k)***"; "i")
      | gsub("(?<k>bearer\\s+)\\S+"; "\(.k)***"; "i")
      | gsub("(?<k>authorization:\\s*([a-z]+\\s+)?)\\S+"; "\(.k)***"; "i")
      | .[0:200]) as $safe |
    "\(now | strftime("%Y-%m-%dT%H:%M:%SZ")) \($pfx)tool=\($tool) \($safe)"
  ' 2>/dev/null
}
# Called by every block path just before exit 2. Falls back to a line without
# tool detail when jq is missing or the payload is not valid JSON.
_agentguard_log_block() {
  local entry
  entry=$(_agentguard_audit_entry "BLOCKED hook=${0##*/} " 2>/dev/null)
  [[ -n "$entry" ]] || entry="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) BLOCKED hook=${0##*/}"
  _agentguard_audit_append "$entry"
}

# Resolve jq before anything else. GUI-launched agents (macOS Dock) often get
# a PATH without /opt/homebrew/bin or /usr/local/bin; without jq a hook cannot
# parse its payload, so fail closed (exit 2; exit 1 is non-blocking in Claude
# Code). audit-log.sh (PostToolUse) cannot block, so it exits 0 silently.
if ! command -v jq >/dev/null 2>&1; then
  for _agentguard_jq in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq /snap/bin/jq; do
    if [[ -x "$_agentguard_jq" ]]; then
      PATH="${_agentguard_jq%/*}:$PATH"
      break
    fi
  done
  unset _agentguard_jq
  if ! command -v jq >/dev/null 2>&1; then
    [[ "${0##*/}" == audit-log.sh ]] && exit 0
    echo "agentguard: jq not found in PATH; blocking tool call (install jq or fix PATH)" >&2
    _agentguard_log_block
    exit 2
  fi
fi

# User-level Cursor hooks (~/.cursor/hooks.json) "Run from ~/.cursor/", not the
# project. Cursor sets CURSOR_PROJECT_DIR ("Workspace root directory"); move
# there so the disabled list and git branch checks see the project.
if [[ -n "${CURSOR_PROJECT_DIR:-}" && "$(pwd -P)" == "$(cd "$HOME/.cursor" 2>/dev/null && pwd -P)" ]]; then
  cd "$CURSOR_PROJECT_DIR" 2>/dev/null || true
fi

_agentguard_disabled_file="${AGENTGUARD_DISABLED_DIRS_FILE:-$HOME/.agentguard/disabled-dirs}"
if [[ -f "$_agentguard_disabled_file" ]]; then
  _agentguard_cur=$(jq -r '.cwd // .tool_input.cwd // empty' <<<"${INPUT:-}" 2>/dev/null)
  if [[ -n "$_agentguard_cur" && -d "$_agentguard_cur" ]]; then
    _agentguard_cur="$(cd "$_agentguard_cur" && { pwd -P 2>/dev/null || pwd; })"
  else
    _agentguard_cur="$(pwd -P 2>/dev/null || pwd)"
  fi
  while IFS= read -r _agentguard_line || [[ -n "$_agentguard_line" ]]; do
    _agentguard_line="${_agentguard_line%$'\r'}"
    _agentguard_line="${_agentguard_line#"${_agentguard_line%%[![:space:]]*}"}"
    _agentguard_line="${_agentguard_line%"${_agentguard_line##*[![:space:]]}"}"
    [[ -z "$_agentguard_line" || "${_agentguard_line:0:1}" == "#" ]] && continue
    # Strip trailing slashes; "/" becomes "" and then matches every path.
    _agentguard_line="${_agentguard_line%"${_agentguard_line##*[!/]}"}"
    if [[ "$_agentguard_cur" == "$_agentguard_line" || "$_agentguard_cur" == "$_agentguard_line"/* ]]; then
      _agentguard_skip=1
      break
    fi
  done < "$_agentguard_disabled_file"
  if [[ -n "${_agentguard_skip:-}" ]]; then
    # Cursor permission hooks need {"permission":"allow"} on stdout even when
    # skipped; postToolUse (audit-log.sh) needs no output.
    if [[ "${0##*/}" != audit-log.sh ]] && jq -e '.hook_event_name == "preToolUse" or .hook_event_name == "beforeMCPExecution" or ((has("command") or has("file_path")) and ((has("tool_input") or has("toolInput")) | not))' <<<"${INPUT:-}" >/dev/null 2>&1; then
      echo '{"permission":"allow"}'
    fi
    exit 0
  fi
  unset _agentguard_cur _agentguard_line
fi
unset _agentguard_disabled_file
