#!/bin/bash
# hooks/block-env-read.sh
#
# Blocks Read, Write, Edit, fs_read, and fs_write tools on sensitive file paths.
# Shared hook — used by both Claude (Read/Write/Edit/Grep/Glob/NotebookEdit) and Kiro (fs_read/fs_write).
#
# Covers: .env files (not .env.example and other templates), direnv (.envrc),
# private keys, tool credential stores, shell history, agent config and auth files.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"
echo "$INPUT" | jq empty >/dev/null 2>&1 || { echo "agentguard: invalid hook payload; blocking tool call" >&2; exit 2; }
# Claude:  .tool_input.file_path (Read/Write/Edit), .tool_input.path (Grep/Glob),
#          .tool_input.notebook_path (NotebookEdit), .tool_input.pattern (Glob), .tool_input.glob (Grep)
# Kiro:    .tool_input.path (fs_write),   .tool_input.operations[].path (fs_read)
# Grok:    .toolInput.path / .toolInput.target_file (read_file), .toolInput.file_path (search_replace)
# Collect all candidate paths; trim whitespace via sed (xargs would split paths with spaces).
PATHS=$(echo "$INPUT" | jq -r '
  (.file_path // ""),
  (.tool_input.file_path // ""),
  (.tool_input.path // ""),
  (.tool_input.notebook_path // ""),
  (if .tool_name == "Glob" then .tool_input.pattern // "" else "" end),
  (if .tool_name == "Grep" then .tool_input.glob // "" else "" end),
  (.toolInput.file_path // ""),
  (.toolInput.path // ""),
  (.toolInput.target_file // ""),
  (.tool_input.operations // [] | .[].path // ""),
  (.toolInput.operations // [] | .[].path // ""),
  (.tool_input.edits // [] | .[].file_path // "")
' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)
# Cursor: flat .command/.file_path payload must get permission JSON on stdout (see _check-disabled.sh)
_is_cursor() { echo "$INPUT" | jq -e '(has("command") or has("file_path")) and ((has("tool_input") or has("toolInput")) | not)' >/dev/null 2>&1; }
_allow() { if _is_cursor; then echo '{"permission":"allow"}'; fi; exit 0; }
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if _is_cursor; then jq -cn --arg m "$1" '{permission:"deny",user_message:$m}'; elif echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# .env and .env.<suffix> (also Glob forms like .env*), but not committed templates.
ENV_RE='(^|/)\.env([.*][^/]*)?$'
ENV_TEMPLATE_RE='(^|/)\.env(\.[^/]*)?\.(example|sample|template|dist|schema|defaults)$'
# Private keys, keystores and password vaults. Public keys (*.pub) are allowed.
KEY_RE='\.(pem|key|p12|pfx|ppk|jks|keystore|p8|gpg|kdbx|ovpn)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)(_sk)?$|(^|/)deploy_key$'
# Credential stores of common tools. Names must be whole path segments, so
# src/credentialsService.ts or k8s/sealed-secret.yaml do not match.
STORE_RE='\.envrc$|(^|/)\.?secrets?/|(^|/)secrets?\.(ya?ml|json|env)$|(^|/)credentials(\.(json|ya?ml|xml|ini|txt|csv))?$|(^|/)\.(aws|ssh|kube|azure|gnupg|password-store)(/|$)|(^|/)\.config/gcloud(/|$)|(^|/)\.config/gh/hosts\.yml$|(^|/)\.docker/config\.json$|(^|/)\.terraform\.d/credentials|(^|/)terraform\.tfstate(\.backup)?$|(^|/)\.(netrc|npmrc|pypirc|terraformrc|git-credentials|boto|s3cfg|pgpass|my\.cnf|vault-token|bash_history|zsh_history)$|(^|/)\.authinfo(\.gpg)?$|(^|/)wp-config\.php$'
# Agent config and auth files (agentguard's own and other agents').
AGENT_RE='/\.agentguard($|/)|/\.claude/(settings\.json|hooks/|CLAUDE\.md$)|/\.kiro/(settings\.json|hooks/|agents/|KIRO\.md$)|(^|/)\.cursor/(hooks\.json$|hooks/|mcp\.json$)|/\.grok/(hooks/|config\.toml|AGENTS\.md$|skills/|memory/)|(^|/)\.grok/(hooks/|config\.toml|AGENTS\.md$)|(^|/)\.codex/(config\.toml|auth\.json|hooks\.json)$|(^|/)\.gemini/(settings\.json|oauth_creds\.json|GEMINI\.md)$|(^|/)\.copilot(/|$)'
SENSITIVE_RE="$KEY_RE|$STORE_RE|$AGENT_RE"
# Claude settings, user or project level. Project-local settings override user
# settings, so a write there can set disableAllHooks for the project.
SETTINGS_RE='(^|/)\.claude/settings(\.local)?\.json$|(^|/)\.claude\.json$'

while IFS= read -r FILE; do
  if echo "$FILE" | grep -qE "$SETTINGS_RE"; then
    _grok_block "Blocked: '$FILE' is a Claude settings file. Project-local settings (.claude/settings.local.json) can set disableAllHooks and turn off every guardrail, so agents may not touch it. Ask the user to make the change."
  fi
  if { echo "$FILE" | grep -qE "$ENV_RE" && ! echo "$FILE" | grep -qE "$ENV_TEMPLATE_RE"; } \
     || echo "$FILE" | grep -qE "$SENSITIVE_RE"; then
    _grok_block "Blocked: reading sensitive file '$FILE' is not permitted globally. If a value from this file is needed, ask the user to supply it directly."
  fi
done <<< "$PATHS"

_allow
