#!/bin/bash
# hooks/block-main-branch.sh
#
# 1. Blocks any force push: -f / --force / --force-with-lease (also inside short
#    flag clusters like -fu), +refspec, --mirror and --all.
# 2. Blocks history-writing git commands on a protected branch: commit, merge,
#    cherry-pick, rebase, revert, am. Also blocks pushes that would implicitly
#    push the protected current branch (git push, git push -u origin,
#    git push origin HEAD).
# 3. Blocks explicit pushes targeting protected branches regardless of current branch,
#    including refspec-style pushes (HEAD:main, refs/heads/main, 'main').
#
# Protected branches: defaults to main and master. Override sources in order:
#   1. AGENTGUARD_PROTECTED_BRANCHES env var (wins if set)
#   2. ~/.agentguard/config (written by install.sh; sourced when env unset)
# Both accept a comma-separated list, e.g.:
#   export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop,trunk"
#
# Shared hook — used by Claude (Bash), Kiro (execute_bash), Codex (Bash),
# Cursor (beforeShellExecution) and Grok (run_terminal_command / Bash).
# Static deny rules cannot inspect git state — this hook runs in the actual
# working directory (the payload .cwd when present) so it can call git at runtime.
#
# Parsing strategy: the command is split into statements on shell separators
# (newline ; & | ( ) ` and $( ) while tracking single/double quotes, so
# `echo "git commit"` stays one echo statement. Heredoc bodies (<<WORD ... WORD)
# are dropped first. Each statement is then read word by word:
#   - `cd <dir>` statements set the directory used for branch detection
#   - `git checkout/switch <branch>` changes the branch seen by later statements
#   - git global options (-C, -c, --no-pager, --git-dir, ...) are skipped to
#     find the real subcommand
# This is not a full shell parser: eval, bash -c "...", xargs, aliases and
# nested quotes inside "$( )" are not followed.
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

# Cheap prefilter: nothing to check unless the command mentions git at all.
[[ "$COMMAND" == *git* ]] || _allow

# Detect the branch where the agent's shell is: the payload .cwd follows the
# agent's `cd` (Claude Code, Codex, Cursor). Missing or not a directory: keep
# the hook's own working directory.
_cwd=$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null)
if [[ -n "$_cwd" && -d "$_cwd" ]]; then cd "$_cwd" 2>/dev/null || true; fi
unset _cwd

# Load config file when env var unset. Env var still wins so users can
# override per-shell without touching the config.
#
# The config file is user-writable, so we never `source` it — that would
# execute any shell payload an attacker placed there. We parse only the one
# variable we expect and validate its value against a strict character set
# before accepting it. Anything that doesn't match falls back to the default.
_config_file="${AGENTGUARD_CONFIG_FILE:-$HOME/.agentguard/config}"
if [[ -z "${AGENTGUARD_PROTECTED_BRANCHES:-}" && -f "$_config_file" ]]; then
  _cfg_val=$(grep -E '^AGENTGUARD_PROTECTED_BRANCHES=' "$_config_file" \
             | tail -n1 \
             | sed -E 's/^AGENTGUARD_PROTECTED_BRANCHES=//; s/^"//; s/"$//' \
             | tr -d '[:space:]')
  if [[ -n "$_cfg_val" && "$_cfg_val" =~ ^[a-zA-Z0-9_,/.-]+$ ]]; then
    AGENTGUARD_PROTECTED_BRANCHES="$_cfg_val"
  fi
  unset _cfg_val
fi

# Build the protected-branch regex from AGENTGUARD_PROTECTED_BRANCHES (comma-separated).
# Default: main,master
_raw="${AGENTGUARD_PROTECTED_BRANCHES:-main,master}"
# Convert comma-separated list to a safe alternation regex:
#   1. Split on commas, strip whitespace, drop empty entries.
#   2. Escape regex metacharacters so "feat.*" in the env var doesn't accidentally
#      match all feature branches — branch names are literals, not patterns.
#   3. Join with | using awk (paste -sd '|' - is not POSIX and fragile on some platforms).
PROTECTED_RE=$(echo "$_raw" | tr ',' '\n' \
  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
  | grep -v '^$' \
  | sed 's/[.^$*+?()[\]\\|{}]/\\&/g' \
  | awk '{printf "%s%s", sep, $0; sep="|"} END{print ""}')

_is_protected() { [[ -n "$1" ]] && echo "$1" | grep -qE "^(${PROTECTED_RE})$"; }
_unquote() { local v="${1//\'/}"; printf '%s' "${v//\"/}"; }

_block_branch() {
  _grok_block "Blocked: currently on '$1'. Never commit or push directly to '$1'. Steps: 1. git pull origin $1; 2. git checkout -b <type>/<short-description>; 3. Make changes and commit on that branch; 4. When ready, open a PR to merge back into $1"
}
_block_force() {
  _grok_block "Blocked: force push is not permitted in any form. Rewrite history locally if needed, then open a PR instead of force-pushing."
}
_block_target() {
  _grok_block "Blocked: pushing directly to a protected branch (${_raw}) is not permitted. Open a PR instead."
}

# Print one shell statement per line. Drops heredoc bodies, joins lines ending
# in a backslash or inside an open quote, and breaks on separators outside
# single quotes (inside double quotes only $( and ` start a new statement,
# since command substitution still runs there). Only the first heredoc on a
# line is recognised.
_statements() {
  printf '%s\n' "$COMMAND" | awk -v sq="'" '
    BEGIN { hd_re = "<<-?[ \t]*[\"" sq "]?[A-Za-z_][A-Za-z0-9_]*" }
    {
      if (skip != "") {                       # inside a heredoc body
        l = $0; if (strip) sub(/^\t+/, "", l)
        if (l == skip) skip = ""
        next
      }
      line = $0; tmp = line; gsub(/<<</, "", tmp)
      if (q == "" && match(tmp, hd_re)) {
        w = substr(tmp, RSTART + 2, RLENGTH - 2)
        strip = (substr(w, 1, 1) == "-")
        gsub(/[- \t"]/, "", w); gsub(sq, "", w)
        pending = w
      }
      cont = 0; n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == sq) { out = out c; if (c == sq) q = ""; continue }
        if (c == "\\") {
          if (i == n) { cont = 1; continue }
          out = out c substr(line, i + 1, 1); i++; continue
        }
        if (q == "\"") {
          if (c == "\"") { q = ""; out = out c; continue }
          if (c == "`" || c == ")" || (c == "$" && substr(line, i + 1, 1) == "(")) {
            print out; out = ""; if (c == "$") i++; continue
          }
          out = out c; continue
        }
        if (c == sq || c == "\"") { q = c; out = out c; continue }
        if (c ~ /[;&|()`]/) { print out; out = ""; continue }
        out = out c
      }
      if (q != "" || cont) { out = out " " } else { print out; out = "" }
      if (pending != "") { skip = pending; pending = "" }
    }
    END { if (out != "") print out }'
}

cd_dir=""                       # directory from `cd` statements ("" = hook cwd)
sw_set=0; sw_key=""; sw_branch=""   # branch switched to earlier in this command

while IFS= read -r -u 3 stmt; do
  read -ra t <<<"$stmt"
  i=0
  # Skip prefixes that still run the next word as a command.
  while (( i < ${#t[@]} )); do
    case "${t[i]}" in
      sudo|command|exec|time|nohup|'!'|'{'|if|then|else|elif|do|while|until) i=$((i + 1)) ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;   # VAR=value assignment
      *) break ;;
    esac
  done
  cmd="${t[i]:-}"; i=$((i + 1))

  # cd <dir>: later git statements run there. Expands ~ and $HOME; relative
  # targets stack on the previous cd. Nonexistent dirs are ignored.
  if [[ "$cmd" == cd ]]; then
    d=$(_unquote "${t[i]:-~}")
    # shellcheck disable=SC2016,SC2088  # matching the literal text, not expanding it
    case "$d" in
      '~'|'$HOME'|'${HOME}') d="$HOME" ;;
      '~/'*)       d="$HOME/${d#\~/}" ;;
      '$HOME/'*)   d="$HOME/${d#\$HOME/}" ;;
      '${HOME}/'*) d="$HOME/${d#\$\{HOME\}/}" ;;
    esac
    [[ "$d" != /* && -n "$cd_dir" ]] && d="$cd_dir/$d"
    if [[ -d "$d" ]]; then cd_dir="$d"; sw_set=0; fi
    continue
  fi
  [[ "$cmd" == git ]] || continue

  # Global options before the subcommand. Options that pick the repo are kept
  # for branch detection; -c values are never passed on (they can run code).
  gargs=(); [[ -n "$cd_dir" ]] && gargs=(-C "$cd_dir")
  while (( i < ${#t[@]} )); do
    o="${t[i]}"
    case "$o" in
      -C|--git-dir|--work-tree)      gargs+=("$o" "$(_unquote "${t[i+1]:-}")"); i=$((i + 2)) ;;
      --git-dir=*|--work-tree=*)     gargs+=("$(_unquote "$o")"); i=$((i + 1)) ;;
      -c|--namespace|--config-env)   i=$((i + 2)) ;;
      -*)                            i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  sub="${t[i]:-}"; i=$((i + 1))
  args=("${t[@]:i}")

  key="${gargs[*]}"
  if (( sw_set )) && [[ "$sw_key" == "$key" ]]; then
    BRANCH="$sw_branch"
  else
    # Detached HEAD gives an empty string: not blocked (anonymous commits).
    BRANCH=$(git "${gargs[@]}" branch --show-current 2>/dev/null)
  fi

  case "$sub" in
    checkout|switch)
      # Track the branch later statements will run on. -b/-c always switch;
      # a lone positional switches only when it names a local or remote branch
      # (otherwise `git checkout file && git commit` would slip through).
      new=""; found=0; pos=()
      for ((j = 0; j < ${#args[@]}; j++)); do
        a="${args[j]}"
        case "$a" in
          -b|-B|-c|-C|--create|--force-create|--orphan) new=$(_unquote "${args[j+1]:-}"); found=1; break ;;
          --detach) found=1; break ;;
          --) pos=(x x); break ;;
          -*) ;;
          *) pos+=("$(_unquote "$a")") ;;
        esac
      done
      if (( ! found )) && (( ${#pos[@]} == 1 )) \
         && [[ -n $(git "${gargs[@]}" for-each-ref --format=x "refs/heads/${pos[0]}" "refs/remotes/*/${pos[0]}" 2>/dev/null) ]]; then
        new="${pos[0]}"; found=1
      fi
      if (( found )); then sw_set=1; sw_key="$key"; sw_branch="$new"; fi
      ;;
    commit)
      [[ " ${args[*]} " == *" --dry-run "* ]] && continue
      _is_protected "$BRANCH" && _block_branch "$BRANCH"
      ;;
    merge|cherry-pick|rebase|revert|am)
      [[ " ${args[*]} " == *" --abort "* || " ${args[*]} " == *" --quit "* ]] && continue
      _is_protected "$BRANCH" && _block_branch "$BRANCH"
      ;;
    push)
      remote=""; refs=(); tags=0; skip_next=0
      for a in "${args[@]}"; do
        if (( skip_next )); then skip_next=0; continue; fi
        case "$a" in
          --force|--force-with-lease|--force-with-lease=*|--mirror|--all|--branches) _block_force ;;
          --tags) tags=1 ;;
          -o|--push-option) skip_next=1 ;;
          --*) ;;
          -*f*) _block_force ;;          # -f and clusters such as -fu, -uf
          -*) ;;
          *) a=$(_unquote "$a")
             if [[ -z "$remote" ]]; then remote="$a"; else refs+=("$a"); fi ;;
        esac
      done
      for r in "${refs[@]}"; do
        [[ "$r" == +* ]] && _block_force
        case "$r" in
          HEAD|@) _is_protected "$BRANCH" && _block_branch "$BRANCH"; continue ;;
          *:*) dst="${r#*:}" ;;
          *) dst="$r" ;;
        esac
        _is_protected "${dst#refs/heads/}" && _block_target
      done
      # No refspec: git pushes the current branch (unless only tags are pushed).
      if (( ${#refs[@]} == 0 && ! tags )) && _is_protected "$BRANCH"; then
        _block_branch "$BRANCH"
      fi
      ;;
  esac
done 3< <(_statements)

_allow
