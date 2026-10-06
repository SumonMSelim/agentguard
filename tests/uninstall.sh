#!/bin/bash
# tests/uninstall.sh — agentguard uninstall test suite
#
# Installs into a temp HOME, verifies files are present, uninstalls, verifies
# they are gone. Also tests --dry-run leaves everything intact.
#
# Usage:
#   ./tests/uninstall.sh
#
# Requirements: bash, jq

set -uo pipefail
# Note: -e is intentionally omitted. bash arithmetic ((pass++)) returns exit 1
# when the result is zero, which would abort the script under set -e.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

# ── helpers ───────────────────────────────────────────────────────────────────

check_true() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n" "$label"
    ((fail++))
  fi
}

check_false() {
  local label="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n" "$label"
    ((fail++))
  fi
}

jq_true() {
  local label="$1" query="$2" file="$3"
  if jq -e "$query" "$file" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n" "$label"
    ((fail++))
  fi
}

jq_false() {
  local label="$1" query="$2" file="$3"
  if ! jq -e "$query" "$file" >/dev/null 2>&1; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n" "$label"
    ((fail++))
  fi
}

# Run install.sh with a fake HOME so we don't touch the real one
FAKE_HOME=$(mktemp -d)
FAKE_PROJECT=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJECT"' EXIT

run_install()   { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@") >/dev/null 2>&1; }
run_uninstall() { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" uninstall "$@") >/dev/null 2>&1; }

HOOKS=(audit-log.sh block-destructive-ops.sh block-env-read.sh block-env.sh block-main-branch.sh block-system-installs.sh)
CURSOR_FILES=(
  "AGENTS.md"
  ".cursor/hooks.json"
  ".cursor/hooks/audit-log.sh"
  ".cursor/hooks/block-destructive-ops.sh"
  ".cursor/hooks/block-env-read.sh"
  ".cursor/hooks/block-env.sh"
  ".cursor/hooks/block-main-branch.sh"
  ".cursor/hooks/block-self-edit.sh"
  ".cursor/hooks/block-system-installs.sh"
)

# ── Claude ────────────────────────────────────────────────────────────────────

echo "uninstall claude — dry-run leaves files intact"
run_install claude
run_uninstall claude --dry-run

check_true  "CLAUDE.md still present after dry-run"    test -f "$FAKE_HOME/.claude/CLAUDE.md"
check_true  "settings.json still present after dry-run" test -f "$FAKE_HOME/.claude/settings.json"
for h in "${HOOKS[@]}"; do
  check_true "hook $h still present after dry-run" test -f "$FAKE_HOME/.claude/hooks/$h"
done

echo ""
echo "uninstall claude — removes files"
run_uninstall claude

check_false "CLAUDE.md removed"     test -f "$FAKE_HOME/.claude/CLAUDE.md"
for h in "${HOOKS[@]}"; do
  check_false "hook $h removed" test -f "$FAKE_HOME/.claude/hooks/$h"
done

echo ""
echo "uninstall claude — settings.json unmerged"
# Re-install so settings.json exists, then uninstall and check
run_install claude
run_uninstall claude

S="$FAKE_HOME/.claude/settings.json"
jq_false "block-env.sh removed from PreToolUse"         '[.hooks.PreToolUse[]?.hooks[]?.command | test("block-env.sh")]             | any' "$S"
jq_false "block-main-branch.sh removed from PreToolUse" '[.hooks.PreToolUse[]?.hooks[]?.command | test("block-main-branch.sh")]     | any' "$S"
jq_false "audit-log.sh removed from PostToolUse"        '[.hooks.PostToolUse[]?.hooks[]?.command | test("audit-log.sh")]            | any' "$S"
jq_false "deny force-push rules removed"                '(.permissions.deny // []) | map(test("force")) | any'                 "$S"
jq_false "ask git commit removed"                       '(.permissions.ask  // []) | map(test("git commit")) | any'                 "$S"
jq_false "attribution removed"                          'has("attribution")'                                                        "$S"
jq_false "includeGitInstructions removed"               'has("includeGitInstructions")'                                             "$S"
jq_false "block-env-read.sh removed from PreToolUse"    '[.hooks.PreToolUse[]?.hooks[]?.command | test("block-env-read.sh")]        | any' "$S"
jq_false "includeCoAuthoredBy removed"                'has("includeCoAuthoredBy")'                                                "$S"
jq_false "gitAttribution removed"                       'has("gitAttribution")'                                                     "$S"
jq_false "disableGitWorkflow removed"                   'has("disableGitWorkflow")'                                                 "$S"

echo ""
echo "uninstall claude — settings.json preserves user keys"
# Install with a pre-existing settings.json that has a user key
echo '{"model":"claude-opus-4","permissions":{"allow":["MyCustomRule"]}}' \
  > "$FAKE_HOME/.claude/settings.json"
run_install claude
run_uninstall claude

jq_true  "user model key preserved"       '.model == "claude-opus-4"'                                "$S"
jq_true  "user allow rule preserved"      '.permissions.allow | map(test("MyCustomRule")) | any'     "$S"

echo ""
echo "uninstall claude — no permissions key pollution when user had none"
# Start with a settings.json that has no permissions key at all
echo '{"model":"claude-sonnet"}' > "$FAKE_HOME/.claude/settings.json"
run_install claude
run_uninstall claude

jq_false "permissions key absent after unmerge" 'has("permissions")' "$S"
jq_true  "model key still present"              '.model == "claude-sonnet"' "$S"

# #76: install + uninstall restores the user file exactly.
# round_trip <label> <json>
round_trip() {
  local label="$1" before="$2"
  printf '%s\n' "$before" > "$S"
  run_install claude
  run_uninstall claude
  check_true "$label: file restored" diff <(jq -S . <<<"$before") <(jq -S . "$S")
}

echo ""
echo "uninstall claude — removes only what install added (#76)"
round_trip "pre-existing allow entry and legacy key" \
  '{"permissions":{"allow":["WebSearch","Bash(make *)"]},"includeCoAuthoredBy":true}'
round_trip "user Bash hook, no empty arrays added" \
  '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-hook.sh"}]}]}}'
round_trip "no permissions key" '{"model":"claude-sonnet"}'
round_trip "user defaultMode plan" '{"permissions":{"defaultMode":"plan"}}'
round_trip "user attribution" '{"attribution":{"commit":"x","pr":"y"},"includeGitInstructions":true}'
check_false "install record removed after uninstall" test -f "$FAKE_HOME/.agentguard/claude-added.json"

# ── Kiro ──────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall kiro — dry-run leaves files intact"
run_install kiro
run_uninstall kiro --dry-run

check_true "KIRO.md still present after dry-run"          test -f "$FAKE_HOME/.kiro/KIRO.md"
check_true "agentguard.json still present after dry-run"  test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
check_true "3.x hooks json still present after dry-run"   test -f "$FAKE_HOME/.kiro/hooks/agentguard.json"
for h in "${HOOKS[@]}"; do
  check_true "hook $h still present after dry-run" test -f "$FAKE_HOME/.kiro/hooks/$h"
done

echo ""
echo "uninstall kiro — removes files"
run_uninstall kiro

check_false "KIRO.md removed"            test -f "$FAKE_HOME/.kiro/KIRO.md"
check_false "agentguard.json removed"    test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
check_false "3.x hooks json removed"     test -f "$FAKE_HOME/.kiro/hooks/agentguard.json"
for h in "${HOOKS[@]}"; do
  check_false "hook $h removed" test -f "$FAKE_HOME/.kiro/hooks/$h"
done

# ── Codex ─────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall codex — dry-run leaves files intact"
run_install codex
check_false "nothing written to ~/AGENTS.md"         test -f "$FAKE_HOME/AGENTS.md"
run_uninstall codex --dry-run

check_true "AGENTS.md still present after dry-run"  test -f "$FAKE_HOME/.codex/AGENTS.md"
check_true "hooks.json still present after dry-run" test -f "$FAKE_HOME/.codex/hooks.json"
for h in "${HOOKS[@]}"; do
  check_true "codex hook $h still present after dry-run" test -f "$FAKE_HOME/.codex/hooks/$h"
done

echo ""
echo "uninstall codex — removes files"
run_uninstall codex

check_false "AGENTS.md removed"       test -f "$FAKE_HOME/.codex/AGENTS.md"
check_false "hooks.json removed"      test -f "$FAKE_HOME/.codex/hooks.json"
check_false "hooks dir removed"       test -d "$FAKE_HOME/.codex/hooks"
check_false "no hooks.json backups"   compgen -G "$FAKE_HOME/.codex/hooks*"
for h in "${HOOKS[@]}"; do
  check_false "codex hook $h removed" test -f "$FAKE_HOME/.codex/hooks/$h"
done

echo ""
echo "uninstall codex — keeps user hooks in hooks.json"
mkdir -p "$FAKE_HOME/.codex"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-hook.sh"}]}]}}\n' > "$FAKE_HOME/.codex/hooks.json"
run_install codex
jq_true  "user hook kept after install"     '[.hooks.PreToolUse[].hooks[].command] | index("my-hook.sh") != null' "$FAKE_HOME/.codex/hooks.json"
jq_true  "our hook merged in"               '[.hooks.PreToolUse[].hooks[].command] | any(test("block-env.sh"))'  "$FAKE_HOME/.codex/hooks.json"
run_install codex
jq_true  "re-install does not duplicate"    '[.hooks.PreToolUse[].hooks[].command | select(test("block-env.sh"))] | length == 1' "$FAKE_HOME/.codex/hooks.json"
run_uninstall codex
jq_true  "user hook kept after uninstall"   '.hooks.PreToolUse[0].hooks == [{"type":"command","command":"my-hook.sh"}]' "$FAKE_HOME/.codex/hooks.json"
jq_false "our hooks gone"                   '[.. | .command? // empty | test("codex/hooks/")] | any' "$FAKE_HOME/.codex/hooks.json"
jq_false "empty PostToolUse dropped"        '.hooks | has("PostToolUse")' "$FAKE_HOME/.codex/hooks.json"
rm -rf "$FAKE_HOME/.codex"

echo ""
echo "install codex — migrates agentguard-created ~/AGENTS.md"
cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$FAKE_HOME/AGENTS.md"
printf '<!-- agentguard:created -->\n\n---\n\n<!-- agentguard:skill:go -->\nGO\n<!-- agentguard:end-skill:go -->\n' >> "$FAKE_HOME/AGENTS.md"
run_install codex --skills none
check_false "legacy ~/AGENTS.md removed"        test -f "$FAKE_HOME/AGENTS.md"
check_true  "~/.codex/AGENTS.md created"        test -f "$FAKE_HOME/.codex/AGENTS.md"
check_true  "legacy skill carried over"         grep -qF '<!-- agentguard:skill:go -->' "$FAKE_HOME/.codex/AGENTS.md"
run_uninstall codex
check_false "~/.codex/AGENTS.md removed"        test -f "$FAKE_HOME/.codex/AGENTS.md"

echo ""
echo "install codex — migrates pre-marker ~/AGENTS.md with old Codex header"
{ head -n 2 "$SCRIPT_DIR/agents/codex/AGENTS.md"
  printf '> Codex instruction file. Keep in sync with agents/claude/CLAUDE.md.\n> Enforcement is instruction-only.\n\n'
  tail -n +3 "$SCRIPT_DIR/agents/codex/AGENTS.md"; } > "$FAKE_HOME/AGENTS.md"
run_install codex
check_false "legacy ~/AGENTS.md removed"        test -f "$FAKE_HOME/AGENTS.md"
run_uninstall codex

echo ""
echo "install codex — leaves ~/AGENTS.md while grok is installed"
run_install grok
run_install codex
check_true  "~/AGENTS.md kept for grok"         test -f "$FAKE_HOME/AGENTS.md"
check_true  "~/.codex/AGENTS.md created"        test -f "$FAKE_HOME/.codex/AGENTS.md"
run_uninstall codex
check_true  "~/AGENTS.md kept after codex uninstall" test -f "$FAKE_HOME/AGENTS.md"
run_uninstall grok
check_false "~/AGENTS.md removed after grok uninstall" test -f "$FAKE_HOME/AGENTS.md"

# ── Gemini ────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall gemini — dry-run leaves files intact"
run_install gemini
run_uninstall gemini --dry-run
check_true "GEMINI.md still present after dry-run"     test -f "$FAKE_HOME/.gemini/GEMINI.md"
check_true "settings.json still present after dry-run" test -f "$FAKE_HOME/.gemini/settings.json"
for h in "${HOOKS[@]}"; do
  check_true "gemini hook $h still present after dry-run" test -f "$FAKE_HOME/.gemini/hooks/$h"
done

echo ""
echo "uninstall gemini — removes files, keeps user GEMINI.md content"
run_uninstall gemini
check_false "GEMINI.md removed"      test -f "$FAKE_HOME/.gemini/GEMINI.md"
check_false "settings.json removed"  test -f "$FAKE_HOME/.gemini/settings.json"
check_false "hooks dir removed"      test -d "$FAKE_HOME/.gemini/hooks"
printf 'MY GEMINI RULES\n' > "$FAKE_HOME/.gemini/GEMINI.md"
run_install gemini --skills go
check_true  "skill appended to user GEMINI.md" grep -qF '<!-- agentguard:skill:go -->' "$FAKE_HOME/.gemini/GEMINI.md"
run_uninstall gemini
check_true  "user GEMINI.md kept"     grep -qx 'MY GEMINI RULES' "$FAKE_HOME/.gemini/GEMINI.md"
check_false "skill section stripped"  grep -qF 'agentguard:skill' "$FAKE_HOME/.gemini/GEMINI.md"
rm -rf "$FAKE_HOME/.gemini"

echo ""
echo "uninstall copilot — dry-run leaves files intact, then removes them"
run_install copilot
run_uninstall copilot --dry-run
check_true  "copilot agentguard.json still present after dry-run" test -f "$FAKE_HOME/.copilot/hooks/agentguard.json"
check_true  "copilot instructions still present after dry-run"   test -f "$FAKE_HOME/.copilot/copilot-instructions.md"
run_uninstall copilot
check_false "copilot agentguard.json removed"  test -f "$FAKE_HOME/.copilot/hooks/agentguard.json"
check_false "copilot instructions removed"     test -f "$FAKE_HOME/.copilot/copilot-instructions.md"
check_false "copilot hooks dir removed"        test -d "$FAKE_HOME/.copilot/hooks"
rm -rf "$FAKE_HOME/.copilot"

# ── Windsurf ──────────────────────────────────────────────────────────────────

WS_DIR="$FAKE_HOME/.codeium/windsurf"
echo ""
echo "uninstall windsurf — dry-run leaves files intact"
run_install windsurf
run_uninstall windsurf --dry-run
check_true "global_rules.md still present after dry-run" test -f "$WS_DIR/memories/global_rules.md"
check_true "hooks.json still present after dry-run"      test -f "$WS_DIR/hooks.json"
for h in "${HOOKS[@]}"; do
  check_true "windsurf hook $h still present after dry-run" test -f "$WS_DIR/hooks/$h"
done

echo ""
echo "uninstall windsurf — removes files, keeps user hooks.json entries"
run_uninstall windsurf
check_false "global_rules.md removed" test -f "$WS_DIR/memories/global_rules.md"
check_false "hooks.json removed"      test -f "$WS_DIR/hooks.json"
check_false "hooks dir removed"       test -d "$WS_DIR/hooks"
echo '{"hooks":{"post_cascade_response":[{"command":"log.sh"}]}}' > "$WS_DIR/hooks.json"
run_install windsurf
run_uninstall windsurf
jq_true "user hooks.json entry kept" '. == {"hooks":{"post_cascade_response":[{"command":"log.sh"}]}}' "$WS_DIR/hooks.json"
rm -rf "$FAKE_HOME/.codeium"

# ── Cursor ────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall cursor — dry-run leaves files intact"
run_install cursor
run_uninstall cursor --dry-run

for f in "${CURSOR_FILES[@]}"; do
  check_true "cursor file $f still present after dry-run" test -f "$FAKE_PROJECT/$f"
done

echo ""
echo "uninstall cursor — removes files"
run_uninstall cursor

for f in "${CURSOR_FILES[@]}"; do
  check_false "cursor file $f removed" test -f "$FAKE_PROJECT/$f"
done

# ── CLI wrapper ───────────────────────────────────────────────────────────────

WRAPPER="$FAKE_HOME/.local/bin/agentguard"

echo ""
echo "CLI wrapper — survives single-agent uninstall (#87)"
run_install claude
run_install kiro
run_uninstall claude
check_true  "wrapper kept after uninstall claude"  test -x "$WRAPPER"
run_uninstall kiro
check_true  "wrapper kept after uninstall kiro"    test -x "$WRAPPER"

echo ""
echo "CLI wrapper — Homebrew Cellar path rewritten to opt (#87)"
BREW_PREFIX=$(mktemp -d)
CELLAR="$BREW_PREFIX/Cellar/agentguard/9.9.9/libexec"
mkdir -p "$CELLAR"
cp -R "$SCRIPT_DIR/hooks" "$SCRIPT_DIR/agents" "$SCRIPT_DIR/skills" "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/VERSION" "$CELLAR/"
(cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$CELLAR/install.sh" claude) >/dev/null 2>&1
check_true  "wrapper points at opt path"   grep -qF "$BREW_PREFIX/opt/agentguard/libexec/install.sh" "$WRAPPER"
check_false "wrapper has no Cellar path"   grep -qF "/Cellar/" "$WRAPPER"
(cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$CELLAR/install.sh" uninstall claude) >/dev/null 2>&1
rm -rf "$BREW_PREFIX"

echo ""
echo "cursor hooks.json — merge keeps user hooks, refreshes ours, no dupes"
CUR_JSON="$FAKE_PROJECT/.cursor/hooks.json"
mkdir -p "$FAKE_PROJECT/.cursor"
# A user hook plus an older agentguard hooks.json (no preToolUse / beforeMCPExecution,
# beforeReadFile without failClosed).
cat > "$CUR_JSON" <<'JSON'
{"version":1,"hooks":{
  "beforeShellExecution":[{"command":"./mine.sh"},{"command":".cursor/hooks/block-env.sh"}],
  "beforeReadFile":[{"command":".cursor/hooks/block-env-read.sh"}],
  "afterFileEdit":[{"command":"./fmt.sh"}]}}
JSON
run_install cursor
run_install cursor
jq_true  "user beforeShellExecution hook kept"   '[.hooks.beforeShellExecution[].command] | index("./mine.sh") != null' "$CUR_JSON"
jq_true  "user afterFileEdit hook kept"          '.hooks.afterFileEdit == [{"command":"./fmt.sh"}]' "$CUR_JSON"
jq_true  "no duplicate commands per event"       '[.hooks[] | [.[].command] | length == (unique | length)] | all' "$CUR_JSON"
jq_true  "old entry refreshed (failClosed)"      '.hooks.beforeReadFile == [{"command":".cursor/hooks/block-env-read.sh","failClosed":true}]' "$CUR_JSON"
jq_true  "preToolUse Write|Delete registered"    '.hooks.preToolUse[] | select(.matcher == "Write|Delete" and .command == ".cursor/hooks/block-env-read.sh")' "$CUR_JSON"
jq_true  "beforeMCPExecution registered"         '.hooks.beforeMCPExecution[0].command == ".cursor/hooks/block-env-read.sh"' "$CUR_JSON"
jq_true  "block-self-edit registered"            '[.hooks.beforeShellExecution[].command] | index(".cursor/hooks/block-self-edit.sh") != null' "$CUR_JSON"
run_uninstall cursor
jq_true  "uninstall keeps only user hooks"       '.hooks == {"beforeShellExecution":[{"command":"./mine.sh"}],"afterFileEdit":[{"command":"./fmt.sh"}]}' "$CUR_JSON"
rm -rf "$FAKE_PROJECT/.cursor"

echo ""
echo "cursor --user — installs to ~/.cursor, tracked, uninstall removes only ours"
mkdir -p "$FAKE_HOME/.cursor"
echo '{"version":1,"hooks":{"stop":[{"command":"./hooks/mine.sh"}]}}' > "$FAKE_HOME/.cursor/hooks.json"
run_install cursor --user
USER_JSON="$FAKE_HOME/.cursor/hooks.json"
check_true  "user hook scripts installed"        test -x "$FAKE_HOME/.cursor/hooks/block-self-edit.sh"
check_false "no project .cursor written"         test -d "$FAKE_PROJECT/.cursor"
check_false "no project AGENTS.md written"       test -f "$FAKE_PROJECT/AGENTS.md"
jq_true  "user hooks.json commands are absolute" "[.hooks[][].command | select(. != \"./hooks/mine.sh\") | startswith(\"$FAKE_HOME/.cursor/hooks/\")] | all" "$USER_JSON"
jq_true  "user hooks.json keeps user stop hook"  '.hooks.stop == [{"command":"./hooks/mine.sh"}]' "$USER_JSON"
check_true  "cursor-user tracked for upgrade"    grep -q 'cursor-user' "$FAKE_HOME/.agentguard/config"
run_uninstall cursor --user
check_false "user hook scripts removed"          test -f "$FAKE_HOME/.cursor/hooks/block-self-edit.sh"
jq_true  "user hooks.json back to user entries"  '. == {"version":1,"hooks":{"stop":[{"command":"./hooks/mine.sh"}]}}' "$USER_JSON"
check_false "cursor-user untracked"              grep -q 'cursor-user' "$FAKE_HOME/.agentguard/config"
rm -rf "$FAKE_HOME/.cursor"

# ── all ───────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall all — removes everything"
run_install all
run_install cursor --user
run_uninstall all

check_false "CLI wrapper removed (all)"           test -f "$WRAPPER"
check_false "cursor --user hook scripts removed (all)" test -f "$FAKE_HOME/.cursor/hooks/block-env-read.sh"
check_false "cursor --user hooks.json removed (all)"   test -f "$FAKE_HOME/.cursor/hooks.json"

check_false "CLAUDE.md removed (all)"             test -f "$FAKE_HOME/.claude/CLAUDE.md"
check_false "KIRO.md removed (all)"               test -f "$FAKE_HOME/.kiro/KIRO.md"
check_false "agentguard.json removed (all)"       test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
check_false "kiro 3.x hooks json removed (all)"   test -f "$FAKE_HOME/.kiro/hooks/agentguard.json"
check_false "AGENTS.md removed (all)"             test -f "$FAKE_HOME/AGENTS.md"
check_false "codex AGENTS.md removed (all)"       test -f "$FAKE_HOME/.codex/AGENTS.md"
check_false "codex hooks.json removed (all)"      test -f "$FAKE_HOME/.codex/hooks.json"
check_false "GEMINI.md removed (all)"             test -f "$FAKE_HOME/.gemini/GEMINI.md"
check_false "gemini settings.json removed (all)"  test -f "$FAKE_HOME/.gemini/settings.json"
check_false "gemini hooks dir removed (all)"      test -d "$FAKE_HOME/.gemini/hooks"
check_false "copilot instructions removed (all)"  test -f "$FAKE_HOME/.copilot/copilot-instructions.md"
check_false "copilot hooks dir removed (all)"     test -d "$FAKE_HOME/.copilot/hooks"
check_false "windsurf global_rules.md removed (all)" test -f "$FAKE_HOME/.codeium/windsurf/memories/global_rules.md"
check_false "windsurf hooks.json removed (all)"   test -f "$FAKE_HOME/.codeium/windsurf/hooks.json"
check_false "windsurf hooks dir removed (all)"    test -d "$FAKE_HOME/.codeium/windsurf/hooks"
check_false "~/.agentguard/config removed (all)"  test -f "$FAKE_HOME/.agentguard/config"
check_false "~/.agentguard/ dir removed (all)"    test -d "$FAKE_HOME/.agentguard"
for h in "${HOOKS[@]}"; do
  check_false "claude hook $h removed (all)" test -f "$FAKE_HOME/.claude/hooks/$h"
  check_false "kiro hook $h removed (all)"   test -f "$FAKE_HOME/.kiro/hooks/$h"
  check_false "codex hook $h removed (all)"  test -f "$FAKE_HOME/.codex/hooks/$h"
  check_false "gemini hook $h removed (all)" test -f "$FAKE_HOME/.gemini/hooks/$h"
done

for f in "${CURSOR_FILES[@]}"; do
  check_false "cursor file $f removed (all)" test -f "$FAKE_PROJECT/$f"
done

# ── skill idempotency ─────────────────────────────────────────────────────────

echo ""
echo "skill idempotency — re-running install does not duplicate skills"
run_install claude
run_install claude  # second install
run_install claude  # third install

# Count how many core skills exist (the expected number of sentinels)
# Read the front-matter into a variable first: `awk | grep -q` under pipefail
# fails at random when grep exits early and awk dies of SIGPIPE.
core_count=0
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
  fm=$(awk '/^---/{if(NR==1){in_fm=1;next}else{exit}} in_fm{print}' "$skill_dir/SKILL.md" 2>/dev/null)
  grep -qE '(^|[^A-Za-z0-9_])core([^A-Za-z0-9_]|$)' <<<"$fm" && core_count=$((core_count + 1)) || true
done

count=$(grep -c 'agentguard:skill:' "$FAKE_HOME/.claude/CLAUDE.md" 2>/dev/null || echo 0)
if [[ "$count" -eq "$core_count" ]]; then
  printf "  PASS  each core skill sentinel appears exactly once after 3 installs (%s skills)\n" "$core_count"
  ((pass++))
else
  printf "  FAIL  skill sentinels: %s found, expected %s (one per core skill)\n" "$count" "$core_count"
  ((fail++))
fi

# ── user-owned instruction files ──────────────────────────────────────────────

echo ""
echo "uninstall claude — keeps user-authored CLAUDE.md, strips only skill sections"
run_uninstall claude
printf 'MY OWN RULES\n' > "$FAKE_HOME/.claude/CLAUDE.md"
run_install claude
check_true  "skills appended to user CLAUDE.md"   grep -qF '<!-- agentguard:skill:' "$FAKE_HOME/.claude/CLAUDE.md"
run_uninstall claude
check_true  "user CLAUDE.md kept"                 test -f "$FAKE_HOME/.claude/CLAUDE.md"
check_true  "custom line present"                 grep -qxF 'MY OWN RULES' "$FAKE_HOME/.claude/CLAUDE.md"
check_false "agentguard skill sections gone"      grep -qF 'agentguard:' "$FAKE_HOME/.claude/CLAUDE.md"
check_true  "CLAUDE.md restored to user content"  diff <(printf 'MY OWN RULES\n') "$FAKE_HOME/.claude/CLAUDE.md"

echo ""
echo "uninstall codex — keeps user-authored AGENTS.md, strips only skill sections"
mkdir -p "$FAKE_HOME/.codex"
printf 'MY AGENTS\n' > "$FAKE_HOME/.codex/AGENTS.md"
run_install codex
check_true  "skills appended to user AGENTS.md"   grep -qF '<!-- agentguard:skill:' "$FAKE_HOME/.codex/AGENTS.md"
run_uninstall codex
check_true  "user AGENTS.md kept"                 test -f "$FAKE_HOME/.codex/AGENTS.md"
check_true  "custom line present"                 grep -qxF 'MY AGENTS' "$FAKE_HOME/.codex/AGENTS.md"
check_false "agentguard skill sections gone"      grep -qF 'agentguard:' "$FAKE_HOME/.codex/AGENTS.md"
check_false "no hooks left under ~/.codex"        compgen -G "$FAKE_HOME/.codex/hooks*"

echo ""
echo "uninstall codex — keeps user-authored ~/AGENTS.md"
printf 'MY HOME AGENTS\n' > "$FAKE_HOME/AGENTS.md"
run_install codex
run_uninstall codex
check_true  "user ~/AGENTS.md kept"               diff <(printf 'MY HOME AGENTS\n') "$FAKE_HOME/AGENTS.md"

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
