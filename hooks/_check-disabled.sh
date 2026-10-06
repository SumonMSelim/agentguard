#!/bin/bash
# hooks/_check-disabled.sh
#
# Sourced (NOT executed) by every guardrail hook. If the current directory
# is in the agentguard disabled list, exits 0 — short-circuiting the host
# hook so all its checks are skipped.
#
# The disabled list lives at ~/.agentguard/disabled-dirs, one absolute path
# per line. A directory matches if it equals an entry, or is below one
# (ancestor disables descendants). Blank lines and `#` comments ignored.
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
#     tool_input (Claude/Kiro) or toolInput (Grok).
#   - Output: {"permission":"allow"|"deny","user_message":..,"agent_message":..}
#     (beforeReadFile: permission + user_message only). Snake_case.
#   - "Exit code 0 - Hook succeeded, use the JSON output. Exit code 2 - Block
#     the action (equivalent to returning permission: "deny")."
#   - "Invalid JSON or a response that doesn't match the hook's schema blocks
#     the action." Empty stdout on exit 0 is therefore printed as allow JSON.
#   - postToolUse output is optional ("no output is required"); audit-log.sh
#     prints nothing.

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
    exit 2
  fi
fi

_agentguard_disabled_file="${AGENTGUARD_DISABLED_DIRS_FILE:-$HOME/.agentguard/disabled-dirs}"
if [[ -f "$_agentguard_disabled_file" ]]; then
  _agentguard_cur="$(pwd -P 2>/dev/null || pwd)"
  while IFS= read -r _agentguard_line || [[ -n "$_agentguard_line" ]]; do
    _agentguard_line="${_agentguard_line%$'\r'}"
    _agentguard_line="${_agentguard_line#"${_agentguard_line%%[![:space:]]*}"}"
    _agentguard_line="${_agentguard_line%"${_agentguard_line##*[![:space:]]}"}"
    [[ -z "$_agentguard_line" || "${_agentguard_line:0:1}" == "#" ]] && continue
    if [[ "$_agentguard_cur" == "$_agentguard_line" || "$_agentguard_cur" == "$_agentguard_line"/* ]]; then
      _agentguard_skip=1
      break
    fi
  done < "$_agentguard_disabled_file"
  if [[ -n "${_agentguard_skip:-}" ]]; then
    # Cursor permission hooks need {"permission":"allow"} on stdout even when
    # skipped; postToolUse (audit-log.sh) needs no output.
    if [[ "${0##*/}" != audit-log.sh ]] && jq -e '(has("command") or has("file_path")) and ((has("tool_input") or has("toolInput")) | not)' >/dev/null 2>&1; then
      echo '{"permission":"allow"}'
    fi
    exit 0
  fi
  unset _agentguard_cur _agentguard_line
fi
unset _agentguard_disabled_file
