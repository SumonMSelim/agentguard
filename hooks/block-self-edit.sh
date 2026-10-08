#!/bin/bash
# hooks/block-self-edit.sh
#
# Blocks bash commands that would modify agentguard's own configuration —
# settings.json, hook scripts, instruction files. Without this an agent can
# disable its own guardrails via the Bash tool:
#
#   echo '{}' > ~/.claude/settings.json
#   sed -i '/block-/d' ~/.claude/settings.json
#   rm ~/.claude/hooks/block-main-branch.sh
#   cp /tmp/empty.sh ~/.claude/hooks/block-main-branch.sh
#
# Read/Write/Edit tool calls on the same paths are handled by
# block-env-read.sh's SENSITIVE_RE — this hook only covers the Bash surface.
#
# Strategy: two-pass match. First detect that a self-config path is mentioned
# anywhere in the command, then detect a write-style operator anywhere in the
# same command. Both must hold; this avoids the false-positive of `echo
# "~/.claude/settings.json"` and the false-negative of greedy prefix consumption
# from a single all-in-one regex.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# shellcheck disable=SC2034  # read by the sourced _check-disabled.sh
INPUT=$(cat)

# Skip all checks if the current directory is in the agentguard disabled list.
# Also defines the shared payload and block helpers (_allow, _grok_block).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"
COMMAND=$(_agentguard_command) || _agentguard_invalid_payload

# `agentguard disable` (or install.sh disable) turns every guardrail off for a
# directory. Block it at any statement position, including behind sudo, env
# (with -u / VAR=val) or inline VAR=val prefixes that strip the Claude session
# variables. Checked before the git allowlist so `git status && agentguard
# disable` is still caught.
_STMT_START='(^|[;&|(`]|\$\()[[:space:]]*(([^[:space:]]*/)?sudo[[:space:]]+)?(([^[:space:]]*/)?env([[:space:]]+(-u[[:space:]]*[^[:space:]]+|-[a-zA-Z]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*))*[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
_DISABLE_CMD='(([^[:space:];&|]*/)?agentguard|((bash|sh|zsh)[[:space:]]+([^[:space:]]+[[:space:]]+)*)?[^[:space:];&|]*install\.sh)[[:space:]]+disable([[:space:]]|$)'
if echo "$COMMAND" | grep -qE "${_STMT_START}${_DISABLE_CMD}"; then
  _grok_block "Blocked: agents may not run 'agentguard disable'. Disabling guardrails requires the user to confirm in their own terminal."
fi

# Allowlist: git invocations don't modify ~/.claude/ etc directly. Commit
# messages and diff hunks routinely contain text that would otherwise trip
# the two-pass detector (e.g. "fix ~/.claude hook" in a commit message).
# Only a single git statement is allowlisted: any separator (; & | newline
# $( backtick) or redirect falls through to the detector, so
# `git status; rm -rf ~/.claude/hooks` is still caught.
if echo "$COMMAND" | grep -qE '^[[:space:]]*git([[:space:]]|$)' \
  && [[ "$COMMAND" != *$'\n'* ]] \
  && ! echo "$COMMAND" | grep -qE '[;&|`<>]|\$\('; then
  _allow
fi

# Paths covering agentguard's own configuration across all agents.
# Home-rooted (~, $HOME, ${HOME}, /Users/*, /home/*, /root): the whole agent
# directory is protected as a prefix, whatever follows. Relative / project
# paths: only the specific config files and hook directories.
# shellcheck disable=SC2016 # literal $HOME is matched as text, not expanded
_HOME_ROOT='(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]"'"'"']+|/home/[^/[:space:]"'"'"']+|/root)'
_HOME_CORE="${_HOME_ROOT}/(\.claude|\.agentguard|\.kiro|\.grok|\.cursor/hooks|\.codex|\.gemini|\.copilot|\.codeium)([^a-zA-Z0-9_-]|\$)"
_REL_CORE='(\.claude/(settings(\.local)?\.json|hooks([^a-zA-Z0-9_-]|$)|CLAUDE\.md)|\.claude\.json|\.kiro/(settings\.json|hooks([^a-zA-Z0-9_-]|$)|agents([^a-zA-Z0-9_-]|$)|KIRO\.md)|\.cursor/(hooks\.json|hooks([^a-zA-Z0-9_-]|$))|\.agentguard([^a-zA-Z0-9_-]|$)|\.grok/(hooks([^a-zA-Z0-9_-]|$)|config\.toml|AGENTS\.md|skills([^a-zA-Z0-9_-]|$)|memory([^a-zA-Z0-9_-]|$))|\.gemini/(settings\.json|hooks([^a-zA-Z0-9_-]|$)|GEMINI\.md|AGENTS\.md|config/(hooks\.json|hooks([^a-zA-Z0-9_-]|$)|audit\.log)|antigravity-cli/settings\.json)|\.agents/hooks\.json|\.copilot/(settings\.json|config\.json|hooks([^a-zA-Z0-9_-]|$)|copilot-instructions\.md)|\.github/copilot/settings(\.local)?\.json|\.codeium/windsurf/(hooks\.json|hooks([^a-zA-Z0-9_-]|$)|memories/global_rules\.md|audit\.log)|\.(devin|windsurf)/hooks\.json|\.(claude|kiro|grok|cursor|codex|gemini|copilot)/audit\.log)'
_SELF_CORE="(${_HOME_CORE}|${_REL_CORE})"
# Anchored so "myclaude/..." doesn't false-match.
_SELF_PATH="(^|[^a-zA-Z0-9_-])${_SELF_CORE}"
# Any agent directory name, used where the path is only a prefix (cd target,
# variable value, bind-mount source).
_SELF_DIR='(\.claude|\.agentguard|\.kiro|\.grok|\.cursor|\.codex|\.gemini|\.copilot|\.github/copilot|\.codeium)([^a-zA-Z0-9_-]|$)'

# Write-style operators that, combined with a self-config path, indicate an
# attempt to modify the configuration. Plain `>` is handled separately (only
# when the redirect target is protected) so `echo "~/.claude/x" > notes.md`
# stays allowed.
_W='(^|[^a-zA-Z0-9_-])'
_WRITE_OPS="(${_W}(tee|rm|rmdir|unlink|shred|cp|mv|chmod|chown|install|ln|truncate|dd|sponge|rsync)[[:space:]]|${_W}(sed|perl)[[:space:]]+([^[:space:]]+[[:space:]]+)*-[a-zA-Z]*i|${_W}find[[:space:]].*-(delete|exec|execdir|ok|okdir)([[:space:]]|\$)|${_W}(python[0-9.]*|perl|node|ruby)[[:space:]]+([^[:space:]]+[[:space:]]+)*-[a-zA-Z]*[ec]([[:space:]]|\$))"
# Write op or any redirect, for commands whose protected path is relative to
# a cd target or hidden behind a variable.
_WRITE_OR_REDIRECT="(${_WRITE_OPS}|>)"

_MSG="Blocked: modifying agentguard's own configuration via Bash is not permitted. Settings files, including project-local .claude/settings.local.json, can set disableAllHooks and turn off every guardrail. If you really need to change the hook configuration, edit it from your own shell, outside the agent."

# Redirect whose target is a protected path: > >> >| &> into ~/.claude/...
if echo "$COMMAND" | grep -qE ">[>|]?[[:space:]]*[\"']?([^[:space:];&|<>\"']*/)?${_SELF_CORE}"; then
  _grok_block "$_MSG"
fi

# Container bind mount of a protected directory (or the whole home dir).
if echo "$COMMAND" | grep -qE "${_W}(docker|podman|nerdctl)[[:space:]]" \
  && echo "$COMMAND" | grep -qE "(-v|--volume)([[:space:]]+|=)[\"']?([^[:space:]:\"']*${_SELF_DIR}|${_HOME_ROOT}/?:)|--mount([[:space:]]+|=)[\"']?[^[:space:]]*(src|source)=[^[:space:],:\"']*${_SELF_DIR}"; then
  _grok_block "$_MSG"
fi

# Two-pass: protected path mentioned AND a write op anywhere in the command.
if echo "$COMMAND" | grep -qE "$_SELF_PATH" \
  && echo "$COMMAND" | grep -qE "$_WRITE_OPS"; then
  _grok_block "$_MSG"
fi

# Harmless redirects (fd duplications like 2>&1, >&2, 1>&- and redirects to
# /dev/null) removed, so `cd ~/.claude && ls 2>&1` is not seen as a write by
# the cd/pushd and variable checks below. Any other redirect is kept.
_NO_NOISE=$(echo "$COMMAND" | sed -E 's/[0-9]*>[>|]?[[:space:]]*(&([0-9]+-?|-)|\/dev\/null)([^a-zA-Z0-9_./-]|$)/\3/g')

# cd/pushd into a protected dir, then a write on a relative path:
#   cd ~/.claude && rm -r hooks
if echo "$COMMAND" | grep -qE "${_W}(cd|pushd)[[:space:]]+[\"']?[^[:space:];&|\"']*${_SELF_DIR}" \
  && echo "$_NO_NOISE" | grep -qE "$_WRITE_OR_REDIRECT"; then
  _grok_block "$_MSG"
fi

# Variable indirection: D=~/.claude; rm -rf $D/hooks
if echo "$COMMAND" | grep -qE "(^|[^a-zA-Z0-9_])[A-Za-z_][A-Za-z0-9_]*=[\"']?[^[:space:];&|\"']*${_SELF_DIR}" \
  && echo "$_NO_NOISE" | grep -qE "$_WRITE_OR_REDIRECT"; then
  _grok_block "$_MSG"
fi

_allow
