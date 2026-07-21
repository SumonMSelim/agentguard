#!/bin/bash
# hooks/block-main-branch.sh
#
# 1. Blocks any force-push flag (--force, -f, --force-with-lease) in git push.
# 2. Blocks git commit on protected branches, and git push with no explicit branch
#    (which would implicitly push the current branch). Explicit-target pushes like
#    "git push origin feat/foo" are allowed here; the refspec check handles those.
# 3. Blocks explicit pushes targeting protected branches regardless of current branch,
#    including refspec-style pushes (HEAD:main, refs/heads/main).
#
# Protected branches: defaults to main and master. Override sources in order:
#   1. AGENTGUARD_PROTECTED_BRANCHES env var (wins if set)
#   2. ~/.agentguard/config (written by install.sh; sourced when env unset)
# Both accept a comma-separated list, e.g.:
#   export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop,trunk"
#
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
# Static deny rules cannot inspect git state — this hook runs in the actual
# working directory so it can call git at runtime.
#
# Matching strategy: all git invocations are anchored to a statement boundary —
# start-of-string or a shell separator (;  &&  ||  |  $() — so that a command
# like `echo "git commit"` does not trigger a block.  We do not attempt full
# shell parsing; the anchor eliminates the most common false-positive pattern
# (string arguments containing git subcommands) without adding fragility.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

# Skip all checks if the current directory is in the agentguard disabled list.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-disabled.sh"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // .toolInput.command // ""') || exit 0
# Grok: emit JSON decision on stdout for blocks (in addition to exit 2 + stderr)
_grok_block() { echo "$1" >&2; if echo "$INPUT" | jq -e 'has("hookEventName") or has("toolName")' >/dev/null 2>&1; then printf '{"decision":"deny","reason":"%s"}\n' "$1"; fi; exit 2; }

# Statement-boundary prefix: start-of-string or a shell separator, followed by
# optional whitespace.  Covers:  git …  /  foo && git …  /  foo; git …  /
#   foo | git …  /  $(git …)  — but NOT  echo "git …"
_GIT_STMT='(^|[;&|]|\$\()[[:space:]]*(sudo[[:space:]]+)?git[[:space:]]+'

# Only act on commands that contain an actual git commit or git push invocation.
if ! echo "$COMMAND" | grep -qE "${_GIT_STMT}(commit|push)"; then
  exit 0
fi

# Block any force-push flag, regardless of its position in the command.
# The flag itself doesn't need a statement anchor — it's an argument, not a command.
# A single pattern covers all forms: -f, --force, --force-with-lease[=...] appearing
# anywhere after "git push".
if echo "$COMMAND" | grep -qE "${_GIT_STMT}push.*[[:space:]](-f|--force|--force-with-lease(=[^[:space:]]*)?)([[:space:]]|\$)"; then
  echo "Blocked: force push is not permitted in any form." >&2
  echo "Rewrite history locally if needed, then open a PR instead of force-pushing." >&2
  exit 2
fi

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

# Resolve the directory the git command actually runs in. A command can lead
# with `cd <dir> &&` / `cd <dir>;` to target a different repo than this hook's
# own process cwd — check that dir instead so branch detection matches reality.
# Only the FIRST leading cd is honored (anchored to start-of-string); a cd
# appearing after the first statement separator is not a reliable target
# (could be inside a subshell, conditional, etc.) and is intentionally ignored.
GIT_DIR_ARG=()
if [[ "$COMMAND" =~ ^[[:space:]]*cd[[:space:]]+([^\;\&\|]+)[[:space:]]*(\&\&|\;) ]]; then
  _cd_target="${BASH_REMATCH[1]}"
  _cd_target="${_cd_target%"${_cd_target##*[![:space:]]}"}"
  _cd_target="${_cd_target%\"}"; _cd_target="${_cd_target#\"}"
  _cd_target="${_cd_target%\'}"; _cd_target="${_cd_target#\'}"
  if [[ -d "$_cd_target" ]]; then
    GIT_DIR_ARG=(-C "$_cd_target")
  fi
  unset _cd_target
fi

# Detect current branch.
# Note: in detached HEAD state --show-current returns an empty string, so the
# branch checks below are skipped. Committing in detached HEAD creates an
# anonymous commit on no branch; this is intentionally not blocked.
BRANCH=$(git "${GIT_DIR_ARG[@]}" branch --show-current 2>/dev/null)

if echo "$BRANCH" | grep -qE "^(${PROTECTED_RE})$"; then
  _block_msg() {
    local m="Blocked: currently on '$BRANCH'. Never commit or push directly to '$BRANCH'. Steps: 1. git pull origin $BRANCH; 2. git checkout -b <type>/<short-description>; 3. Make changes and commit on that branch; 4. When ready, open a PR to merge back into $BRANCH"
    _grok_block "$m"
  }

  # Always block commits on protected branches
  if echo "$COMMAND" | grep -qE "${_GIT_STMT}commit"; then
    _block_msg; exit 2
  fi

  # Block pushes only when no explicit remote branch is given, which would
  # implicitly push the current branch to the remote.
  # "git push" / "git push origin"     → blocked
  # "git push origin feat/foo"         → allowed (explicit target)
  if echo "$COMMAND" | grep -qE "${_GIT_STMT}push"; then
    if ! echo "$COMMAND" | grep -qE "${_GIT_STMT}push[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+"; then
      _block_msg; exit 2
    fi
  fi
fi

# Also block explicit pushes targeting any protected branch regardless of current branch,
# including refspec syntax like HEAD:main or refs/heads/develop.
# Uses [: ] (colon or space) rather than [:\s] — \s is not interpreted as whitespace
# inside bracket expressions by BSD/GNU grep -E, so a space literal is required.
# Uses ([[:space:]]|$) after the branch name so trailing flags like --tags don't bypass.
if echo "$COMMAND" | grep -qE "${_GIT_STMT}push[[:space:]]+.*[: ](refs/heads/)?(${PROTECTED_RE})([[:space:]]|\$)"; then
  _grok_block "Blocked: pushing directly to a protected branch (${_raw}) is not permitted. Open a PR instead."
fi

exit 0
