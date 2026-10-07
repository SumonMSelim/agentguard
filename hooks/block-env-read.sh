#!/bin/bash
# hooks/block-env-read.sh
#
# Blocks Read, Write, Edit, fs_read, and fs_write tools on sensitive file paths.
# Shared hook — used by Claude (Read/Write/Edit/Grep/Glob/NotebookEdit), Kiro (fs_read/fs_write),
# Antigravity CLI (view_file/write_to_file/replace_file_content and friends),
# Cursor (beforeReadFile), Grok (read_file/search_replace and friends),
# Gemini CLI (read_file/write_file/replace and friends), Copilot CLI
# (view/create/edit/grep/glob) and Windsurf
# (pre_read_code/pre_write_code/pre_mcp_tool_use). Not registered for Codex or
# Copilot apply_patch: that payload holds patch text, not a path.
#
# Covers: .env files (not .env.example and other templates), direnv (.envrc),
# private keys, tool credential stores, shell history, agent config and auth files.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)

# Skip all checks if the current directory is in the agentguard disabled list.
# Also defines the shared payload and block helpers (_allow, _grok_block).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"
echo "$INPUT" | jq empty >/dev/null 2>&1 || _agentguard_invalid_payload
# Claude:  .tool_input.file_path (Read/Write/Edit), .tool_input.path (Grep/Glob),
#          .tool_input.notebook_path (NotebookEdit), .tool_input.pattern (Glob), .tool_input.glob (Grep)
# Kiro:    .tool_input.path (fs_write),   .tool_input.operations[].path (fs_read)
# Grok:    .toolInput.path / .toolInput.target_file (read_file), .toolInput.file_path (search_replace)
# Cursor:  .file_path (beforeReadFile), .tool_input.path or .tool_input.file_path (preToolUse Write/Delete),
#          .tool_input as a JSON string of the MCP tool's params (beforeMCPExecution)
# Gemini:  .tool_input.file_path (read_file/write_file/replace), .tool_input.dir_path
#          (list_directory/glob/grep_search), .tool_input.pattern (glob),
#          .tool_input.include_pattern (grep_search), .tool_input.include[] (read_many_files)
# Copilot: toolArgs, mapped to .tool_input by _check-disabled.sh: .path (view/create/edit/grep/glob),
#          .pattern (glob), .glob (grep/rg)
# Windsurf: .tool_info.file_path (pre_read_code/pre_write_code),
#          .tool_info.mcp_tool_arguments.file_path/.path (pre_mcp_tool_use)
# Antigravity: toolCall.args, mapped to .tool_input by _check-disabled.sh: .file_path
#          (view_file/write_to_file/replace_file_content/multi_replace_file_content),
#          .path (list_dir/find_by_name/grep_search), .Pattern (find_by_name), .Includes (grep_search)
# Collect all candidate paths; trim whitespace via sed (xargs would split paths with spaces).
PATHS=$(echo "$INPUT" | jq -r '
  (if (.tool_input | type) == "string" then .tool_input = ((.tool_input | fromjson? | objects) // {}) else . end) | (.file_path // ""),
  (.tool_input.file_path // ""),
  (.tool_input.path // ""),
  (.tool_input.notebook_path // ""),
  (if .tool_name == "Glob" then .tool_input.pattern // "" else "" end),
  (if .tool_name == "Grep" or .tool_name == "grep" or .tool_name == "rg" then .tool_input.glob // "" else "" end),
  (.toolInput.file_path // ""),
  (.toolInput.path // ""),
  (.toolInput.target_file // ""),
  (.tool_input.operations // [] | .[].path // ""),
  (.toolInput.operations // [] | .[].path // ""),
  (.tool_input.edits // [] | .[].file_path // ""),
  (.tool_input.dir_path // ""),
  (if .tool_name == "glob" then .tool_input.pattern // "" else "" end),
  (if .tool_name == "grep_search" or .tool_name == "search_file_content" then .tool_input.include_pattern // "" else "" end),
  (if .tool_name == "read_many_files" then (.tool_input.include // [] | .[]? | strings) else "" end),
  (if .tool_name == "find_by_name" then .tool_input.Pattern // "" else "" end),
  (if .tool_name == "grep_search" then (.tool_input.Includes // [] | if type == "array" then .[] else . end | strings) else "" end),
  (.tool_info.file_path // ""),
  (.tool_info.mcp_tool_arguments | objects | (.file_path // ""), (.path // ""))
' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)

# .env and .env.<suffix> (also Glob forms like .env*), but not committed templates.
ENV_RE='(^|/)\.env([.*][^/]*)?$'
ENV_TEMPLATE_RE='(^|/)\.env(\.[^/]*)?\.(example|sample|template|dist|schema|defaults)$'
# Private keys, keystores and password vaults. Public keys (*.pub) are allowed.
KEY_RE='\.(pem|key|p12|pfx|ppk|jks|keystore|p8|gpg|kdbx|ovpn)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)(_sk)?$|(^|/)deploy_key$'
# Credential stores of common tools. Names must be whole path segments, so
# src/credentialsService.ts or k8s/sealed-secret.yaml do not match.
STORE_RE='\.envrc$|(^|/)\.?secrets?/|(^|/)secrets?\.(ya?ml|json|env)$|(^|/)credentials(\.(json|ya?ml|xml|ini|txt|csv))?$|(^|/)\.(aws|ssh|kube|azure|gnupg|password-store)(/|$)|(^|/)\.config/gcloud(/|$)|(^|/)\.config/gh/hosts\.yml$|(^|/)\.docker/config\.json$|(^|/)\.terraform\.d/credentials|(^|/)terraform\.tfstate(\.backup)?$|(^|/)\.(netrc|npmrc|pypirc|terraformrc|git-credentials|boto|s3cfg|pgpass|my\.cnf|vault-token|bash_history|zsh_history)$|(^|/)\.authinfo(\.gpg)?$|(^|/)wp-config\.php$'
# Agent config and auth files (agentguard's own and other agents'), and the
# agentguard audit logs (they hold command history).
AGENT_RE='/\.agentguard($|/)|/\.claude/(settings\.json|hooks/|CLAUDE\.md$)|/\.kiro/(settings\.json|hooks/|agents/|KIRO\.md$)|(^|/)\.cursor/(hooks\.json$|hooks/|mcp\.json$)|/\.grok/(hooks/|config\.toml|AGENTS\.md$|skills/|memory/)|(^|/)\.grok/(hooks/|config\.toml|AGENTS\.md$)|(^|/)\.codex/(config\.toml|auth\.json|hooks\.json)$|(^|/)\.gemini/(settings\.json$|oauth_creds\.json$|mcp-oauth-tokens\.json$|GEMINI\.md$|hooks/)|(^|/)\.gemini/(AGENTS\.md$|config/(hooks\.json$|hooks/|audit\.log(\.1)?$)|antigravity-cli/(settings\.json$|antigravity-oauth-token$|jetski-standalone-oauth-token$))|(^|/)\.agents/hooks\.json$|(^|/)\.copilot(/|$)|(^|/)\.codeium/windsurf/(hooks\.json$|hooks/|memories/global_rules\.md$|mcp_config\.json$|audit\.log(\.1)?$)|(^|/)\.config/devin/mcp_config\.json$|(^|/)\.(devin|windsurf)/hooks\.json$|(^|/)\.(claude|kiro|codex|grok|cursor|gemini)/audit\.log(\.1)?$'
SENSITIVE_RE="$KEY_RE|$STORE_RE|$AGENT_RE"
# Claude settings, user or project level. Project-local settings override user
# settings, so a write there can set disableAllHooks for the project.
SETTINGS_RE='(^|/)\.claude/settings(\.local)?\.json$|(^|/)\.claude\.json$'
# Copilot CLI repository settings: disableAllHooks there skips "every hook from
# every source" for the repository, including the user-level agentguard hooks.
COPILOT_SETTINGS_RE='(^|/)\.github/copilot/settings(\.local)?\.json$'

while IFS= read -r FILE; do
  if echo "$FILE" | grep -qE "$SETTINGS_RE"; then
    _grok_block "Blocked: '$FILE' is a Claude settings file. Project-local settings (.claude/settings.local.json) can set disableAllHooks and turn off every guardrail, so agents may not touch it. Ask the user to make the change."
  fi
  if echo "$FILE" | grep -qE "$COPILOT_SETTINGS_RE"; then
    _grok_block "Blocked: '$FILE' is a Copilot CLI repository settings file. It can set disableAllHooks and turn off every guardrail, so agents may not touch it. Ask the user to make the change."
  fi
  # .env names match case-insensitively: on macOS .ENV opens .env.
  if { echo "$FILE" | grep -qiE "$ENV_RE" && ! echo "$FILE" | grep -qiE "$ENV_TEMPLATE_RE"; } \
     || echo "$FILE" | grep -qE "$SENSITIVE_RE"; then
    _grok_block "Blocked: reading sensitive file '$FILE' is not permitted globally. If a value from this file is needed, ask the user to supply it directly."
  fi
done <<< "$PATHS"

_allow
