#!/bin/bash
# tests/check.sh — agentguard check command test suite
#
# Verifies that ./install.sh check [agent] correctly reports
# pass/fail for installed and missing installations.
#
# Requirements: bash, jq

set -uo pipefail
# Note: -e intentionally omitted — ((pass++)) exits 1 when result is zero under set -e.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

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

FAKE_HOME=$(mktemp -d)
FAKE_PROJECT=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJECT"' EXIT

run_install() { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@") >/dev/null 2>&1; }
run_check()   { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" check "$@") >/dev/null 2>&1; }

# ── not installed → check fails ───────────────────────────────────────────────

echo "check — nothing installed → exits 1"
check_false "claude check fails when not installed" run_check claude
check_false "kiro check fails when not installed"   run_check kiro
check_false "codex check fails when not installed"  run_check codex
check_false "cursor check fails when not installed" run_check cursor
check_false "all check fails when not installed"    run_check all

# ── fully installed → check passes ───────────────────────────────────────────

echo ""
echo "check — fully installed → exits 0"
run_install all

check_true "claude check passes after install" run_check claude
check_true "kiro check passes after install"   run_check kiro
check_true "codex check passes after install"  run_check codex
check_true "cursor check passes after install" run_check cursor
check_true "all check passes after install"    run_check all

# ── partial install → check fails ────────────────────────────────────────────

echo ""
echo "check — missing hook → exits 1"
rm "$FAKE_HOME/.claude/hooks/block-env.sh"
check_false "claude check fails with missing hook" run_check claude

echo ""
echo "check — missing instruction file → exits 1"
rm "$FAKE_HOME/.claude/CLAUDE.md"
check_false "claude check fails with missing CLAUDE.md" run_check claude

echo ""
echo "check — missing settings.json → exits 1"
rm "$FAKE_HOME/.claude/settings.json"
check_false "claude check fails with missing settings.json" run_check claude

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
