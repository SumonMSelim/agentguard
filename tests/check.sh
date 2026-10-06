#!/bin/bash
# tests/check.sh — agentguard check command test suite
#
# Verifies that `agentguard check` (or ./install.sh check) correctly reports
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
check_false "grok check fails when not installed"   run_check grok
check_false "all check fails when not installed"    run_check all

# ── fully installed → check passes ───────────────────────────────────────────

echo ""
echo "check — fully installed → exits 0"
run_install all

check_true "claude check passes after install" run_check claude
check_true "kiro check passes after install"   run_check kiro
check_true "codex check passes after install"  run_check codex
check_true "cursor check passes after install" run_check cursor
check_true "grok check passes after install"   run_check grok
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

echo ""
echo "check — codex hooks → exits 1 when broken"
chmod -x "$FAKE_HOME/.codex/hooks/block-env.sh"
check_false "codex check fails with non-executable hook" run_check codex
chmod +x "$FAKE_HOME/.codex/hooks/block-env.sh"
cp "$FAKE_HOME/.codex/hooks.json" "$FAKE_HOME/.codex/hooks.json.keep"
jq '.hooks.PreToolUse[0].hooks |= .[1:]' "$FAKE_HOME/.codex/hooks.json.keep" > "$FAKE_HOME/.codex/hooks.json"
check_false "codex check fails with unregistered hook" run_check codex
rm "$FAKE_HOME/.codex/hooks.json"
check_false "codex check fails with missing hooks.json" run_check codex
mv "$FAKE_HOME/.codex/hooks.json.keep" "$FAKE_HOME/.codex/hooks.json"
check_true  "codex check passes once restored" run_check codex

echo ""
echo "check — cursor hooks → exits 1 when broken"
mv "$FAKE_PROJECT/.cursor/hooks/block-self-edit.sh" "$FAKE_PROJECT/block-self-edit.sh.keep"
check_false "cursor check fails with missing block-self-edit.sh" run_check cursor
mv "$FAKE_PROJECT/block-self-edit.sh.keep" "$FAKE_PROJECT/.cursor/hooks/block-self-edit.sh"
chmod -x "$FAKE_PROJECT/.cursor/hooks/_check-disabled.sh"
check_false "cursor check fails with non-executable _check-disabled.sh" run_check cursor
chmod +x "$FAKE_PROJECT/.cursor/hooks/_check-disabled.sh"
cp "$FAKE_PROJECT/.cursor/hooks.json" "$FAKE_PROJECT/hooks.json.keep"
jq 'del(.hooks.preToolUse)' "$FAKE_PROJECT/hooks.json.keep" > "$FAKE_PROJECT/.cursor/hooks.json"
check_false "cursor check fails with unregistered preToolUse" run_check cursor
mv "$FAKE_PROJECT/hooks.json.keep" "$FAKE_PROJECT/.cursor/hooks.json"
check_true  "cursor check passes once restored" run_check cursor

echo ""
echo "check — cursor --user"
check_false "cursor --user check fails when not installed" run_check cursor --user
run_install cursor --user
check_true  "cursor --user check passes after install" run_check cursor --user

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
