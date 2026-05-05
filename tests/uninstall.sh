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
trap 'rm -rf "$FAKE_HOME"' EXIT

run_install()   { HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@" >/dev/null 2>&1; }
run_uninstall() { HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" uninstall "$@" >/dev/null 2>&1; }

HOOKS=(audit-log.sh block-destructive-ops.sh block-env-read.sh block-env.sh block-main-branch.sh block-system-installs.sh)

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
jq_false "includeCoAuthoredBy removed"                  'has("includeCoAuthoredBy")'                                                "$S"
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

# ── Kiro ──────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall kiro — dry-run leaves files intact"
run_install kiro
run_uninstall kiro --dry-run

check_true "KIRO.md still present after dry-run"          test -f "$FAKE_HOME/.kiro/KIRO.md"
check_true "agentguard.json still present after dry-run"  test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
for h in "${HOOKS[@]}"; do
  check_true "hook $h still present after dry-run" test -f "$FAKE_HOME/.kiro/hooks/$h"
done

echo ""
echo "uninstall kiro — removes files"
run_uninstall kiro

check_false "KIRO.md removed"            test -f "$FAKE_HOME/.kiro/KIRO.md"
check_false "agentguard.json removed"    test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
for h in "${HOOKS[@]}"; do
  check_false "hook $h removed" test -f "$FAKE_HOME/.kiro/hooks/$h"
done

# ── Codex ─────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall codex — dry-run leaves file intact"
run_install codex
run_uninstall codex --dry-run

check_true "AGENTS.md still present after dry-run" test -f "$FAKE_HOME/AGENTS.md"

echo ""
echo "uninstall codex — removes file"
run_uninstall codex

check_false "AGENTS.md removed" test -f "$FAKE_HOME/AGENTS.md"

# ── all ───────────────────────────────────────────────────────────────────────

echo ""
echo "uninstall all — removes everything"
run_install all
run_uninstall all

check_false "CLAUDE.md removed (all)"        test -f "$FAKE_HOME/.claude/CLAUDE.md"
check_false "KIRO.md removed (all)"          test -f "$FAKE_HOME/.kiro/KIRO.md"
check_false "agentguard.json removed (all)"  test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
check_false "AGENTS.md removed (all)"        test -f "$FAKE_HOME/AGENTS.md"
for h in "${HOOKS[@]}"; do
  check_false "claude hook $h removed (all)" test -f "$FAKE_HOME/.claude/hooks/$h"
  check_false "kiro hook $h removed (all)"   test -f "$FAKE_HOME/.kiro/hooks/$h"
done

# ── skill idempotency ─────────────────────────────────────────────────────────

echo ""
echo "skill idempotency — re-running install does not duplicate skills"
run_install claude
run_install claude  # second install
run_install claude  # third install

count=$(grep -c 'agentguard:skill:' "$FAKE_HOME/.claude/CLAUDE.md" 2>/dev/null || echo 0)
if [[ "$count" -eq 1 ]]; then
  printf "  PASS  skill sentinel appears exactly once after 3 installs\n"
  ((pass++))
else
  printf "  FAIL  skill sentinel appears %s times (expected 1)\n" "$count"
  ((fail++))
fi

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
