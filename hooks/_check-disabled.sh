#!/bin/bash
# hooks/_check-disabled.sh
#
# Shared library, sourced (NOT executed) by every guardrail hook after the hook
# has read its payload into INPUT. It resolves jq (fail closed without it),
# defines the audit-log, payload and block helpers (_agentguard_command,
# _agentguard_invalid_payload, _allow, _grok_block), and, if the agent's
# directory is in the agentguard disabled list, exits 0 — short-circuiting the
# host hook so all its checks are skipped.
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
# Cursor output contract (cursor.com/docs/agent/hooks, checked 2026-10-06),
# implemented by _is_cursor/_allow/_grok_block below:
#   - Input: every hook gets conversation_id, generation_id, hook_event_name,
#     workspace_roots, ... at top level. beforeShellExecution adds flat
#     "command"/"cwd"; beforeReadFile adds flat "file_path"/"content". So a
#     Cursor permission payload = top-level command or file_path, and no
#     tool_input (Claude/Kiro/Codex) or toolInput (Grok). preToolUse and
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
#
# Gemini CLI (geminicli.com/docs/hooks/reference, checked 2026-10-06) sends the
# Claude shape: tool_name, tool_input (.command for run_shell_command,
# .file_path for file tools), cwd, hook_event_name "BeforeTool"/"AfterTool".
# "Exit code 2: System Block ... stderr is used as rejection reason"; on exit 0
# empty stdout is fine. So it takes the Claude path: no JSON on stdout.
#
# GitHub Copilot CLI (docs.github.com/en/copilot/reference/hooks-configuration
# and /tutorials/copilot-cli-hooks, checked 2026-10-07) camelCase preToolUse /
# postToolUse send sessionId, timestamp, cwd, toolName and toolArgs. toolArgs
# is "a JSON string containing that tool's arguments" in the tutorial, "parsed
# from JSON string when possible" in the reference, so both forms are read
# (apply_patch sends raw patch text). Below, a toolArgs payload is normalized
# to tool_name/tool_input (raw text becomes tool_input.command, as for Codex
# apply_patch) so every hook reads it like Claude. Deny: "exit code 2 is
# treated as a deny", output {"permissionDecision":"deny",
# "permissionDecisionReason":...}; "Empty output uses default behavior".
#
# Windsurf / Devin Desktop Cascade (docs.devin.ai/desktop/cascade/hooks,
# checked 2026-10-07) sends agent_action_name ("pre_run_command", ...) and
# tool_info: .command_line/.cwd (run_command), .file_path (read_code,
# write_code), .mcp_tool_arguments (mcp_tool_use). "Exit 2 ... The Cascade
# agent will see the error message from stderr. For pre-hooks, this blocks the
# action"; no stdout contract, so it takes the Claude path too.
#
# Google Antigravity CLI (antigravity.google/docs/hooks, checked 2026-10-07)
# PreToolUse/PostToolUse send toolCall {name, args} plus conversationId,
# workspacePaths, stepIdx; no cwd and no event name. args use the tool's own
# names: run_command CommandLine/Cwd, view_file AbsolutePath, write_to_file /
# replace_file_content / multi_replace_file_content TargetFile, list_dir
# DirectoryPath, find_by_name SearchDirectory/Pattern, grep_search
# SearchPath/Includes. Below, a toolCall payload is mapped to tool_name /
# tool_input (.command, .file_path, .path added) and .cwd (args.Cwd, else the
# first workspace path), keeping toolCall for _is_antigravity. The docs give
# the PreToolUse output only: {"decision":"allow"|"deny"|"ask"|..,"reason":..};
# "allow" means "automatic execution" (skips the user's own permission
# prompt), so an allow prints nothing. Deny prints the JSON and exits 0; the
# docs name no exit-code channel. Reports from agy users (not in the docs):
# empty stdout on exit 0 runs the tool, any non-zero exit denies it.

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
    (.tool_name // .tool // .toolName // .agent_action_name // "unknown") as $tool |
    (
      .command //
      .file_path //
      (.tool_info | objects | .command_line // .file_path
        // (if .mcp_tool_name then "\(.mcp_server_name // "")/\(.mcp_tool_name)" else null end)) //
      .tool_input.command //
      .tool_input.file_path //
      .tool_input.path //
      .toolInput.command //
      .toolInput.file_path //
      .toolInput.path //
      .toolInput.target_file //
      (.tool_input.operations // [] | first | .path // empty) //
      (.toolInput.operations // [] | first | .path // empty) //
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

# Shell command from the payload: Cursor (flat .command), Claude/Kiro/Codex
# (.tool_input.command), Grok (.toolInput.command) or Windsurf
# (.tool_info.command_line). Fails on invalid JSON.
_agentguard_command() {
  echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // .tool_info.command_line // ""'
}
# Fail closed on a payload that cannot be parsed.
_agentguard_invalid_payload() { echo "agentguard: invalid hook payload; blocking tool call" >&2; _agentguard_log_block; exit 2; }
# Cursor: flat .command/.file_path, preToolUse and beforeMCPExecution payloads
# must get permission JSON on stdout (see the contract above).
_is_cursor() { echo "$INPUT" | jq -e '.hook_event_name == "preToolUse" or .hook_event_name == "beforeMCPExecution" or ((has("command") or has("file_path")) and ((has("tool_input") or has("toolInput")) | not))' >/dev/null 2>&1; }
_allow() { if _is_cursor; then echo '{"permission":"allow"}'; fi; exit 0; }
# Copilot CLI: toolArgs is Copilot's own field (Grok sends toolName too, but
# with toolInput).
_is_copilot() { echo "$INPUT" | jq -e 'has("toolArgs")' >/dev/null 2>&1; }
# Antigravity: toolCall is its own field (no other agent sends it).
_is_antigravity() { echo "$INPUT" | jq -e 'has("toolCall")' >/dev/null 2>&1; }
# Block: stderr message, BLOCKED audit line, exit 2. Cursor also gets deny JSON
# (block-env-read.sh serves beforeReadFile: permission + user_message only);
# Copilot gets a permissionDecision; Grok gets a JSON decision on stdout.
# Antigravity gets its decision JSON and exit 0 (see the contract above).
_grok_block() {
  echo "$1" >&2
  _agentguard_log_block
  if _is_antigravity; then
    jq -cn --arg m "$1" '{decision:"deny",reason:$m}'
    exit 0
  fi
  if _is_cursor; then
    if [[ "${0##*/}" == block-env-read.sh ]]; then
      jq -cn --arg m "$1" '{permission:"deny",user_message:$m}'
    else
      jq -cn --arg m "$1" '{permission:"deny",user_message:$m,agent_message:$m}'
    fi
  elif _is_copilot; then
    jq -cn --arg m "$1" '{permissionDecision:"deny",permissionDecisionReason:$m}'
  elif echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then
    printf '{"decision":"deny","reason":"%s"}\n' "$1"
  fi
  exit 2
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

# Copilot CLI: map toolName/toolArgs to tool_name/tool_input (see the contract
# above). toolArgs stays, so _is_copilot still holds. Invalid JSON is left
# as is for the hook's own payload check.
if [[ "${INPUT:-}" == *'"toolArgs"'* ]]; then
  _agentguard_norm=$(jq -c 'if has("toolArgs") and (has("tool_input") | not) then
      .tool_name = (.tool_name // .toolName)
      | .tool_input = (.toolArgs
          | if type == "string" then (fromjson? // {command: .}) else . end
          | if type == "object" then . else {} end)
    else . end' <<<"$INPUT" 2>/dev/null) && [[ -n "$_agentguard_norm" ]] && INPUT="$_agentguard_norm"
  unset _agentguard_norm
fi

# Antigravity: map toolCall to tool_name/tool_input/cwd (see the contract
# above). toolCall stays, so _is_antigravity still holds.
if [[ "${INPUT:-}" == *'"toolCall"'* ]]; then
  _agentguard_norm=$(jq -c 'if (.toolCall | type) == "object" and (has("tool_input") | not) then
      ((.toolCall.args | objects) // {}) as $a
      | .tool_name = (.toolCall.name // "")
      | .tool_input = ($a + ({command: $a.CommandLine,
          file_path: ($a.TargetFile // $a.AbsolutePath),
          path: ($a.DirectoryPath // $a.SearchDirectory // $a.SearchPath)}
          | with_entries(select(.value != null))))
      | (.cwd // $a.Cwd // ((.workspacePaths | arrays | .[0]) // null)) as $c
      | if $c then .cwd = $c else . end
    else . end' <<<"$INPUT" 2>/dev/null) && [[ -n "$_agentguard_norm" ]] && INPUT="$_agentguard_norm"
  unset _agentguard_norm
fi

# User-level Cursor hooks (~/.cursor/hooks.json) "Run from ~/.cursor/", not the
# project. Cursor sets CURSOR_PROJECT_DIR ("Workspace root directory"); move
# there so the disabled list and git branch checks see the project.
if [[ -n "${CURSOR_PROJECT_DIR:-}" && "$(pwd -P)" == "$(cd "$HOME/.cursor" 2>/dev/null && pwd -P)" ]]; then
  cd "$CURSOR_PROJECT_DIR" 2>/dev/null || true
fi

_agentguard_disabled_file="${AGENTGUARD_DISABLED_DIRS_FILE:-$HOME/.agentguard/disabled-dirs}"
if [[ -f "$_agentguard_disabled_file" ]]; then
  _agentguard_cur=$(jq -r '.cwd // .tool_input.cwd // .tool_info.cwd // empty' <<<"${INPUT:-}" 2>/dev/null)
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
    if [[ "${0##*/}" != audit-log.sh ]] && _is_cursor; then
      echo '{"permission":"allow"}'
    fi
    exit 0
  fi
  unset _agentguard_cur _agentguard_line
fi
unset _agentguard_disabled_file
