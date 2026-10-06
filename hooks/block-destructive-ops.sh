#!/bin/bash
# hooks/block-destructive-ops.sh
#
# Blocks shell patterns that can cause catastrophic or irreversible damage:
#   - rm targeting filesystem root or bare home directory
#   - recursive rm of the cwd, its parent, .git, * or a top-level system dir
#   - find / -delete, recursive chmod/chown on root or home
#   - filesystem/raw-device writes (mkfs, wipefs, dd of=/dev/sda, > /dev/sda)
#   - overwriting /etc/passwd, shadow, sudoers or hosts; the :(){ :|:& };: fork bomb
#   - pipe-to-shell (curl|bash, wget|sh, bash <(curl), sh -c "$(curl)") — supply chain risk
#
# Shared hook — used by Claude (Bash), Kiro (execute_bash), Codex (Bash),
# Cursor (beforeShellExecution) and Grok (run_terminal_command / Bash).
# Note: general `rm -rf <path>` is NOT blocked — legitimate uses like
# `rm -rf node_modules` or `rm -rf ./dist` are too common to intercept.
# Only anchored, catastrophic targets are blocked here.
#
# Matching strategy: rm, curl, and wget are anchored to a statement boundary
# (start-of-string or a shell separator: ;  &&  ||  |  $() so that a command
# like `echo "rm -rf /"` does not trigger a block.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || { echo "agentguard: invalid hook payload; blocking tool call" >&2; _agentguard_log_block; exit 2; }
# Cursor: flat .command/.file_path, preToolUse and beforeMCPExecution payloads must get permission JSON on stdout (see _check-disabled.sh)
_is_cursor() { echo "$INPUT" | jq -e '.hook_event_name == "preToolUse" or .hook_event_name == "beforeMCPExecution" or ((has("command") or has("file_path")) and ((has("tool_input") or has("toolInput")) | not))' >/dev/null 2>&1; }
_allow() { if _is_cursor; then echo '{"permission":"allow"}'; fi; exit 0; }
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; _agentguard_log_block; if _is_cursor; then jq -cn --arg m "$1" '{permission:"deny",user_message:$m,agent_message:$m}'; elif echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Statement-boundary prefix — see block-main-branch.sh for rationale.
# Boundaries: start, ; & | ( ` and $( ; sudo may carry a path (/usr/bin/sudo).
_STMT_START='(^|[;&|(`]|\$\()[[:space:]]*(([^[:space:]]*/)?sudo[[:space:]]+)?'

# Block rm on filesystem root or bare home directory.
# rm must be at a statement boundary; the catastrophic path follows as an argument.
# Matches: rm /   rm /*   rm -rf /   rm -rf ~   rm -rf ~/   rm -rf ~/*
#          rm $HOME   rm $HOME/   rm $HOME/*   rm ${HOME}
#          and the same targets in single or double quotes: rm "/"   rm "$HOME"
# The path separator [[:space:]] before the target handles both "rm /" (no flags)
# and "rm -rf /" (flags present). A space, separator, ) or ` after ensures we match the full
# argument and don't fire on /var/log or $HOME/projects etc.
# Pattern pieces are single-quoted so grep sees \$ (literal $) and $ (end anchor)
# exactly as written.
_QUOTE="[\"']?"
# shellcheck disable=SC2016
_RM_TARGET='(/[/.]*\*?|~/?\*?|\$(HOME|\{HOME\})/?\*?)'
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}"'rm[[:space:]]([^[:space:]]+[[:space:]]+)*'"${_QUOTE}${_RM_TARGET}${_QUOTE}"'([[:space:];&|)`]|$)'; then
  _grok_block "Blocked: rm on root or home directory is not permitted. If you need to remove specific files, use an explicit path."
fi

# Recursive-flag argument (-r, -rf, -fR, --recursive) anywhere in the same statement.
_RFLAG='[[:space:]]([^;&|]*[[:space:]])?(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)[[:space:]]([^;&|]*[[:space:]])?'
_END='([[:space:];&|)`]|$)'

# Block recursive rm of the cwd, its parent, .git, a bare * or a top-level system dir.
# rm -rf ./build, rm -rf build/ and rm -rf /tmp/x stay allowed.
_RM_RTARGET='((\.\./)*\.\.?/?|(\./)?\*|(\./|\*/)?\.git/?|/(usr|etc|var|bin|sbin|boot|lib[0-9]*|opt|root|home|Users|System|Library|Applications)/?)'
if echo "$COMMAND" | grep -qE "${_STMT_START}rm${_RFLAG}${_QUOTE}${_RM_RTARGET}${_QUOTE}${_END}"; then
  _grok_block "Blocked: recursive rm of the current directory, its parent, .git or a system directory is not permitted. Use an explicit subdirectory path."
fi

# Block find starting at root or home with -delete or -exec rm.
# shellcheck disable=SC2016
_FIND_ROOT='(/[/.]*|~/?|\$(HOME|\{HOME\})/?)'
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}find[[:space:]]+(-[HLP][[:space:]]+)*${_QUOTE}${_FIND_ROOT}${_QUOTE}[[:space:]][^;&|]*(-delete|-exec(dir)?[[:space:]]+(sudo[[:space:]]+)?rm[[:space:]])"; then
  _grok_block "Blocked: find on root or home with -delete or -exec rm is not permitted. Start find from a specific subdirectory."
fi

# Block recursive chmod/chown/chgrp on root or home. chmod -R 755 ./build stays allowed.
if echo "$COMMAND" | grep -qE "${_STMT_START}(chmod|chown|chgrp)${_RFLAG}${_QUOTE}${_RM_TARGET}${_QUOTE}${_END}"; then
  _grok_block "Blocked: recursive chmod/chown on root or home is not permitted. Use an explicit subdirectory path."
fi

# Block filesystem creation, partition edits and raw writes to disk devices.
# dd of=/dev/null and dd of=./img stay allowed.
_DISK='/dev/(sd|hd|vd|xvd|nvme|mmcblk|disk|rdisk)'
if echo "$COMMAND" | grep -qE "${_STMT_START}(mkfs(\.[a-zA-Z0-9]+)?|mke2fs|wipefs)([[:space:]]|\$)" \
  || echo "$COMMAND" | grep -qE "${_STMT_START}(fdisk|parted|sgdisk|shred)[[:space:]][^;&|]*/dev/" \
  || echo "$COMMAND" | grep -qE "${_STMT_START}dd[[:space:]][^;&|]*of=${_QUOTE}${_DISK}" \
  || echo "$COMMAND" | grep -qE ">[[:space:]]*${_QUOTE}${_DISK}"; then
  _grok_block "Blocked: formatting, partitioning or writing raw disk devices is not permitted."
fi

# Block overwriting, moving over or removing core account/host files.
_ETC='/etc/(passwd|shadow|sudoers|hosts)'
if echo "$COMMAND" | grep -qE "(^|[^>])>[[:space:]]*${_QUOTE}${_ETC}${_QUOTE}${_END}" \
  || echo "$COMMAND" | grep -qE "${_STMT_START}rm[[:space:]][^;&|]*${_ETC}${_QUOTE}${_END}" \
  || echo "$COMMAND" | grep -qE "${_STMT_START}(mv|cp)[[:space:]][^;&|]*[[:space:]]${_QUOTE}${_ETC}${_QUOTE}[[:space:]]*([;&|)]|\$)"; then
  _grok_block "Blocked: overwriting or removing /etc/passwd, shadow, sudoers or hosts is not permitted."
fi

# Block the classic :(){ :|:& };: fork bomb.
if echo "$COMMAND" | grep -qE ':\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&'; then
  _grok_block "Blocked: fork bomb is not permitted."
fi

# Block pipe-to-shell patterns (supply chain risk).
# curl/wget/fetch must be at a statement boundary.
# Catches: curl url | bash, wget -O- url | sh, curl url | sudo -E bash, curl url | python3.
# Interpreters (python, node, perl, ruby) only block when reading the script from
# stdin, so curl url | python3 -m json.tool stays allowed.
_SUDO='(sudo([[:space:]]+-[a-zA-Z]+)*[[:space:]]+)?'
_SHELLS='(bash|sh|zsh|fish|dash|ash|ksh)'
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(curl|wget|fetch)[[:space:]].*\|[[:space:]]*${_SUDO}(${_SHELLS}([[:space:]]|\$)|(python[0-9.]*|node|perl|ruby)[[:space:]]*(-[[:space:]]*)?([;&|)]|\$))"; then
  _grok_block "Blocked: pipe-to-shell (curl|bash, wget|sh, etc.) is not permitted. Download the script first, inspect it, then run it explicitly."
fi

# Same risk via substitution: bash <(curl ...), sh -c "$(curl ...)", eval "$(curl ...)".
# shellcheck disable=SC2016
_SUBST='(<\(|\$\(|`)'
if echo "$COMMAND" | grep -qE \
  "${_STMT_START}(${_SHELLS}([[:space:]]+-[a-zA-Z]+)*|eval|source|\.)[[:space:]]+${_QUOTE}${_SUBST}[[:space:]]*(curl|wget|fetch)[[:space:]]"; then
  _grok_block "Blocked: running a downloaded script via bash <(curl ...) or sh -c \"\$(curl ...)\" is not permitted. Download the script first, inspect it, then run it explicitly."
fi

_allow
