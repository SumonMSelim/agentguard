#!/bin/bash
# hooks/block-env.sh
#
# Blocks access to .env files, credential stores (~/.ssh, ~/.aws, ...) or env
# var dumps via shell commands.
# Shared hook — used by Claude (Bash), Kiro (execute_bash), Codex (Bash),
# Cursor (beforeShellExecution), Grok (run_terminal_command / Bash) and
# Gemini CLI (run_shell_command); also Copilot CLI (bash).
#
# LIMITATION: best-effort. block-env-read.sh (Read/Write/Edit tool hook) is the
# primary enforcement layer for file reads; this hook is defence-in-depth for
# the Bash surface only. Not covered by design: indirection through variables
# (f=.env; cat "$f"), wildcards that do not start with `.e` (cat .??v, cat .*),
# encoded or computed names, and reads from scripts on disk.
#
# Matching strategy: quotes are stripped first so `.e""nv` and `".env"` look
# like `.env`. Tool names are anchored to a statement boundary (start-of-string
# or a shell separator: ;  &&  ||  |  (  $()  `) behind optional sudo (also
# /usr/bin/sudo), env, command or VAR=val prefixes, so a command like
# `echo "cat .env"` does not trigger a block. Names are matched lowercased.
# .env templates (.env.example/.sample/.template/.dist) are never treated as
# secrets, and `cp .env.example .env` is allowed because .env is the target.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# shellcheck disable=SC2034  # read by the sourced _check-disabled.sh
INPUT=$(cat)

# Skip all checks if the current directory is in the agentguard disabled list.
# Also defines the shared payload and block helpers (_allow, _grok_block).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"
COMMAND=$(_agentguard_command) || _agentguard_invalid_payload

_ENV_MSG="Blocked: reading .env or credential files, or dumping environment variables, is not permitted. If a secret is needed for this task, ask the user to supply it directly."

# Strip quotes and lowercase (macOS file systems are case-insensitive, so
# .ENV opens .env), then neutralise .env templates so they never count as secrets.
N=$(printf '%s' "$COMMAND" | tr -d "\"'" | tr '[:upper:]' '[:lower:]' | sed -E 's/\.env\.(example|sample|template|dist)([[:space:];|&<>),`]|$)/ENV_TEMPLATE\2/g')

# Statement boundary (start, ; & | ( ` or $( ), then optional sudo/command/nohup/time,
# env [opts] and VAR=val prefixes, then an optional directory (/bin/cat).
# See block-self-edit.sh.
_BOUNDARY='(^|[;&|(`]|\$\()[[:space:]]*'
_ENV_OPT='(-u[[:space:]]*[^[:space:]]+|-[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)'
_STMT_START="${_BOUNDARY}((([^[:space:]]*/)?(sudo|doas)|command|exec|nohup|time)[[:space:]]+|([^[:space:]]*/)?env([[:space:]]+${_ENV_OPT})*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*/)?"

# A .env path argument: .env, .env.local, .envrc, globs like .e* or .en?, with
# any directory prefix (./, ../, */, $HOME/app/, ~/). It must start a word or
# follow = @ < ( , : (--opt=.env, curl -d @.env, open('.env'), host:.env).
_ENV_FILE='([^[:space:];|&<>()]*/)?\.(env(rc)?(\.[A-Za-z0-9_.-]+)?|e[nv]*[*?][^[:space:];|&<>()]*)'
# Credential stores that block-env-read.sh protects for file tools: anything
# under ~/.ssh, ~/.aws, ~/.gnupg, ~/.azure, ~/.password-store, gcloud, plus
# kube/docker/gh configs, netrc-style files, Gemini CLI OAuth tokens, the
# Antigravity CLI token file (its fallback when the OS keyring is unusable), the
# Copilot CLI config (its plaintext token fallback), Windsurf MCP config (holds
# server API keys) and SSH private key names.
_CRED_FILE='([^[:space:];|&<>()]*/)?(\.(ssh|aws|gnupg|azure|password-store)(/[^[:space:];|&<>()]*)?|\.kube/config|\.docker/config\.json|\.config/(gh/hosts\.yml|gcloud(/[^[:space:];|&<>()]*)?|devin/mcp_config\.json)|\.codeium/windsurf/mcp_config\.json|\.(netrc|git-credentials|pgpass|vault-token)|\.gemini/(oauth_creds|mcp-oauth-tokens)\.json|\.gemini/antigravity-cli/(antigravity-oauth-token|jetski-standalone-oauth-token)|\.copilot/config\.json|id_(rsa|dsa|ecdsa|ed25519)(_sk)?)'
_SECRET_FILE="(${_ENV_FILE}|${_CRED_FILE})"
_ENV_END='([[:space:];|&<>),`]|$)'
_SECRET_ARG="(^|[[:space:]=@<(,:])${_SECRET_FILE}${_ENV_END}"

# Viewers, editors, text/binary readers, archivers, uploaders and `source`/`.`:
# block when a .env or credential path is any argument.
_READERS='cat|tac|less|more|head|tail|bat|batcat|zcat|zless|nano|vim|nvim|vi|view|emacs|code|cursor|subl|open|awk|gawk|sed|cut|sort|uniq|base64|base32|xxd|od|hexdump|strings|rev|fold|paste|tr|nl|pr|column|jq|yq|diff|cmp|dd|iconv|tar|zip|7z|gzip|bzip2|xz|zstd|gpg|openssl|curl|wget|http|https|xh|source|\.'
if echo "$N" | grep -qE "${_STMT_START}(${_READERS})([[:space:]][^;|&]*)?${_SECRET_ARG}"; then
  _grok_block "$_ENV_MSG"
fi

# grep-like tools: block only when .env comes after the pattern (a file argument),
# so `ls -a | grep .env` and `rg .env` (searching for the name) stay allowed.
if echo "$N" | grep -qE "${_STMT_START}(grep|egrep|fgrep|rg|ag|ack)([[:space:]]+-[^[:space:]]*)*[[:space:]]+[^-[:space:];|&][^[:space:];|&]*([[:space:]][^;|&]*)?[[:space:]]${_SECRET_FILE}${_ENV_END}"; then
  _grok_block "$_ENV_MSG"
fi

# Copy/move/link: block when .env is a source (not the last argument), so
# `cp .env.example .env` stays allowed while `cp .env /tmp/x` is blocked.
if echo "$N" | grep -qE "${_STMT_START}(cp|mv|install|ln|scp|rsync)[[:space:]]([^;|&]*[[:space:]])?${_SECRET_FILE}[[:space:]]+[^;|&<>[:space:]]"; then
  _grok_block "$_ENV_MSG"
fi

# Inline interpreter code that mentions .env (python -c "open('.env')", node -e ...).
if echo "$N" | grep -qE "${_STMT_START}(python[0-9.]*|node|nodejs|deno|bun|ruby|perl|php)[[:space:]]+(-[A-Za-z]*[cerp]|--eval|--print|eval)[[:space:]].*${_SECRET_ARG}"; then
  _grok_block "$_ENV_MSG"
fi

# Input redirection from .env (cmd < .env), and find/fd/xargs feeding .env to a command.
if echo "$N" | grep -qE "(^|[^<])<[[:space:]]*${_SECRET_FILE}${_ENV_END}" \
  || { echo "$N" | grep -qE "$_SECRET_ARG" \
    && echo "$N" | grep -qE "${_STMT_START}xargs([[:space:]]|\$)|${_STMT_START}(find|fd)[[:space:]].*[[:space:]](-exec|-execdir|-ok|-okdir|-x|-X|--exec|--exec-batch)[[:space:]]"; }; then
  _grok_block "$_ENV_MSG"
fi

# Block printenv and dotenv at a statement boundary (with or without arguments).
if echo "$N" | grep -qE "${_STMT_START}(printenv|dotenv)([[:space:];|&>)]|\$)"; then
  _grok_block "$_ENV_MSG"
fi

# Block `env` used as a dump: only options or VAR=val, no command (env, env -0,
# env | grep). Does NOT block `env VAR=value command` or `env -i command`.
if echo "$N" | grep -qE "${_BOUNDARY}((([^[:space:]]*/)?(sudo|doas)|command|exec|nohup|time)[[:space:]]+)*([^[:space:]]*/)?env([[:space:]]+${_ENV_OPT})*[[:space:]]*(\$|[;|>&)])"; then
  _grok_block "Blocked: bare 'env' to dump environment variables is not permitted. If a secret is needed for this task, ask the user to supply it directly."
fi

# Block shell builtins that list variables: bare export/set, export -p and
# declare/typeset with at most one flag (declare -x). `set -x` stays allowed.
if echo "$N" | grep -qE "${_STMT_START}(set|export([[:space:]]+-p)?|(declare|typeset)([[:space:]]+-[A-Za-z]+)?)[[:space:]]*(\$|[;|>&)])"; then
  _grok_block "$_ENV_MSG"
fi

# Block GitHub CLI auth token exposure.
# gh must be at a statement boundary.
if echo "$COMMAND" | grep -qE "${_STMT_START}gh[[:space:]]+auth[[:space:]]+token"; then
  _grok_block "Blocked: 'gh auth token' exposes the GitHub authentication token. If this token is needed for a task, ask the user to supply it directly."
fi

_allow
