#!/bin/bash
# hooks/block-system-installs.sh
#
# Blocks system-level package manager invocations.
# The agent should use Docker instead, or ask the user for permission first.
#
# Shared hook — used by Claude (Bash), Kiro (execute_bash), Codex (Bash),
# Cursor (beforeShellExecution) and Grok (run_terminal_command / Bash).
# Catches: apt, apt-get, brew, yum, dnf, zypper, pacman, apk, snap, port, nix,
# conda, system gem/cargo installs, global npm/yarn/pnpm/bun, sudo pip installs,
# and pip / python -m pip / uv pip installs outside an active virtualenv.
#
# Matching strategy: package manager names are anchored to a statement boundary
# (start-of-string or a shell separator: ;  &&  ||  |  $() so that a command
# like `echo "brew install foo"` does not trigger a block. Installs inside a
# container (docker run/exec, kubectl exec) and heredoc bodies are skipped.
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

# Split the command into one statement per line, honouring quotes, so that a
# container's quoted script (sh -c "a && b") stays on the container's line.
# Heredoc bodies are dropped (e.g. a Dockerfile written via cat <<EOF) unless
# the heredoc feeds a shell on the host (bash <<EOF).
_statements() {
  awk -v q="'" '
    function flush() { print out; out = "" }
    {
      line = $0
      if (hd != "") { t = line; if (hdtab) sub(/^\t+/, "", t); if (t == hd) hd = ""; next }
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (sq) { out = out c; if (c == q) sq = 0; continue }
        if (dq) {
          out = out c
          if (c == "\\") { i++; out = out substr(line, i, 1) } else if (c == "\"") dq = 0
          continue
        }
        if (c == "\\") { i++; out = out c substr(line, i, 1); continue }
        if (c == q) sq = 1
        else if (c == "\"") dq = 1
        else if (c == ";" || c == "&" || c == "|") { flush(); continue }
        out = out c
      }
      if (sq || dq) { out = out " "; next }
      if (match(line, "<<-?[[:space:]]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*") && substr(line, RSTART - 1, 1) != "<") {
        w = substr(line, RSTART + 2, RLENGTH - 2)
        hdtab = (substr(w, 1, 1) == "-"); if (hdtab) w = substr(w, 2)
        gsub("[[:space:]\"" q "]", "", w)
        if (line ~ /(docker|podman|nerdctl|kubectl)[[:space:]]/ || line !~ /(^|[[:space:];&|])(ba|z|da|k)?sh([[:space:]]|$)/) hd = w
      }
      flush()
    }
    END { if (out != "") print out }'
}

# Words that may precede the real command: VAR=x, sudo/env/command/nohup/
# time/... and their options (-E, -u root, -n 10).
_PFX='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|sudo|doas|env|command|nohup|time|exec|nice|xargs|then|do|else|!|-[ugCnp][[:space:]]+[^[:space:]]+|-[^[:space:]]+)[[:space:]]+'
# Statement start: line start (optionally inside ( or {), a separator left
# inside quotes, $( or backtick, or the opening quote of sh -c "...".
_STMT_START="(^[[:space:]]*[({]*|[;&|\`]|\\\$\\(|(sh|bash|zsh|dash)[[:space:]]+-[a-z]*c[[:space:]]+[\"'])[[:space:]]*(${_PFX})*"
# Options between the manager and its verb: -y, --no-cache, -o k=v.
_OPTS='([[:space:]]+(-[^[:space:]]+|[^[:space:]]+=[^[:space:]]*))*'
_END='([^A-Za-z0-9_-]|$)'
# Rest of the same statement, for flags placed after the package (pacman -S).
_ARGS='([[:space:]]+[^;&|]*)?[[:space:]]'

# Installs inside a container do not touch the host: drop statements that are
# docker/podman/nerdctl run|exec or kubectl exec. Known gap: a $(...) in such
# a statement runs on the host but is not inspected.
_CONTAINER="^[[:space:]]*(${_PFX})*(([^[:space:]]*/)?(docker|podman|nerdctl|docker-compose|podman-compose)${_OPTS}[[:space:]]+((container|compose)${_OPTS}[[:space:]]+)?(run|exec)|kubectl([[:space:]]+[^[:space:]]+)*[[:space:]]+exec)${_END}"
STATEMENTS=$(printf '%s\n' "$COMMAND" | _statements | grep -vE "$_CONTAINER")

_SYS_MSG="Blocked: system package installation is not permitted. Use Docker instead, or ask the user for explicit permission first."
_JS_MSG="Blocked: global npm/yarn/pnpm installs are not permitted. Use a local install inside Docker or the project instead."

# Block system package managers (options may sit between manager and verb).
if echo "$STATEMENTS" | grep -qE \
  -e "${_STMT_START}([^[:space:]]*/)?(apt|apt-get|aptitude|yum|dnf|microdnf|zypper|apk|port|snap|brew|conda|mamba|micromamba)${_OPTS}[[:space:]]+(install|reinstall|localinstall|groupinstall|add|in|upgrade|dist-upgrade|full-upgrade|tap)${_END}" \
  -e "${_STMT_START}([^[:space:]]*/)?(pacman|yay|paru)${_ARGS}(-S[yuw]*|-U|--sync|--upgrade)${_END}" \
  -e "${_STMT_START}([^[:space:]]*/)?nix-env${_ARGS}(-i[A-Za-z]*|--install)${_END}" \
  -e "${_STMT_START}([^[:space:]]*/)?nix${_OPTS}[[:space:]]+profile[[:space:]]+(install|add)${_END}"; then
  _grok_block "$_SYS_MSG"
fi

# gem/cargo install write to system paths unless --user-install / --root is
# given. `bundle exec gem ...` is not statement-anchored, so it is allowed.
if echo "$STATEMENTS" | grep -E "${_STMT_START}gem${_OPTS}[[:space:]]+install${_END}" | grep -qvE -- "[[:space:]]--user-install${_END}"; then
  _grok_block "$_SYS_MSG"
fi
if echo "$STATEMENTS" | grep -E "${_STMT_START}cargo${_OPTS}[[:space:]]+install${_END}" | grep -qvE -- "[[:space:]]--root${_END}"; then
  _grok_block "$_SYS_MSG"
fi

# Block global JS package installs: -g/--global anywhere in the statement.
if echo "$STATEMENTS" | grep -E "${_STMT_START}(npm|pnpm|bun)${_OPTS}[[:space:]]+(install|i|add|update|up)${_END}" \
  | grep -qE -- "[[:space:]](-g|--global|--location=global)([[:space:]]|$)"; then
  _grok_block "$_JS_MSG"
fi
if echo "$STATEMENTS" | grep -qE \
  "${_STMT_START}yarn${_OPTS}[[:space:]]+global[[:space:]]+add"; then
  _grok_block "$_JS_MSG"
fi

# pip, pip3, python[3] -m pip, py -m pip, uv pip. A path-qualified binary
# (.venv/bin/pip, ./venv/bin/python -m pip) names its env and is allowed.
_PIP_LINES=$(echo "$STATEMENTS" | grep -E \
  "${_STMT_START}(pip[0-9.]*|(python[0-9.]*|py)${_OPTS}[[:space:]]+-m[[:space:]]+pip[0-9.]*|uv${_OPTS}[[:space:]]+pip)${_OPTS}[[:space:]]+install${_END}")

if [[ -n "$_PIP_LINES" ]]; then
  # Block sudo pip installs regardless of virtualenv.
  if echo "$_PIP_LINES" | grep -qE "(^|[[:space:];&|(])(sudo|doas)[[:space:]]"; then
    _grok_block "Blocked: sudo pip install is not permitted. Use Docker or a virtualenv instead."
  fi
  # Block pip install outside an active virtualenv. VIRTUAL_ENV is set by
  # activate scripts; sourcing one in the same command also counts.
  # Known gap: conda envs set CONDA_DEFAULT_ENV, not VIRTUAL_ENV, so pip
  # inside a conda env is blocked here unless VIRTUAL_ENV is also set.
  if [[ -z "${VIRTUAL_ENV:-}" ]] && \
     ! echo "$STATEMENTS" | grep -qE "^[[:space:]]*(source|\.)[[:space:]]+[^[:space:]]*bin/activate([[:space:]]|$)"; then
    _grok_block "Blocked: pip install outside a virtualenv is not permitted. Activate a virtualenv first, or use Docker."
  fi
fi

_allow
