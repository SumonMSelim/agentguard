#!/bin/bash
# tests/project.sh — agentguard --project flag test suite (tests use direct script invocation)
#
# Tests per-project skill installation for Claude, Codex, and Cursor.
# Verifies: file creation, skill content, sentinel dedup, dry-run, Kiro warning.
#
# Usage:
#   ./tests/project.sh
#
# Requirements: bash

set -uo pipefail

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

check_count() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s (expected %s, got %s)\n" "$label" "$expected" "$actual"
    ((fail++))
  fi
}

check_output() {
  local label="$1" pattern="$2"
  shift 2
  if "$@" 2>&1 | grep -q "$pattern"; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n" "$label"
    ((fail++))
  fi
}

FAKE_HOME=$(mktemp -d)
TMPROOT=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$TMPROOT"' EXIT

# All project dirs live under TMPROOT — single trap covers all
PROJECT_DIR="$TMPROOT/claude"
PROJECT_DRY="$TMPROOT/dry"
PROJECT_EXISTING="$TMPROOT/existing"
PROJECT_CODEX="$TMPROOT/codex"
PROJECT_KIRO="$TMPROOT/kiro"
PROJECT_CURSOR="$TMPROOT/cursor"
PROJECT_ALL="$TMPROOT/all"
mkdir -p "$PROJECT_DIR" "$PROJECT_DRY" "$PROJECT_EXISTING" \
         "$PROJECT_CODEX" "$PROJECT_KIRO" "$PROJECT_CURSOR" "$PROJECT_ALL"

run_project() {
  HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@" >/dev/null 2>&1
}

run_project_in() {
  local dir="$1"; shift
  (cd "$dir" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@" 2>&1)
}

# ── Claude: creates .claude/CLAUDE.md ─────────────────────────────────────────

echo "claude --project: creates .claude/CLAUDE.md with skill"
run_project_in "$PROJECT_DIR" claude --project --skills go >/dev/null

check_true  "creates .claude/CLAUDE.md"    test -f "$PROJECT_DIR/.claude/CLAUDE.md"
check_true  "skill sentinel present"       grep -qF "agentguard:skill:go" "$PROJECT_DIR/.claude/CLAUDE.md"
check_false "global CLAUDE.md not written" test -f "$FAKE_HOME/.claude/CLAUDE.md"
check_false "settings.json not written"    test -f "$FAKE_HOME/.claude/settings.json"
check_false "hooks not written"            test -d "$FAKE_HOME/.claude/hooks"

# ── Claude: dedup on re-run ────────────────────────────────────────────────────

echo ""
echo "claude --project: dedup on re-run"
run_project_in "$PROJECT_DIR" claude --project --skills go >/dev/null
run_project_in "$PROJECT_DIR" claude --project --skills go >/dev/null

count=$(grep -c "agentguard:skill:go" "$PROJECT_DIR/.claude/CLAUDE.md" 2>/dev/null || echo 0)
check_count "sentinel appears exactly once after 3 installs" 1 "$count"

# ── Claude: dry-run ───────────────────────────────────────────────────────────

echo ""
echo "claude --project --dry-run: no files written"
run_project_in "$PROJECT_DRY" claude --project --skills go --dry-run >/dev/null

check_false "no .claude/CLAUDE.md written in dry-run" test -f "$PROJECT_DRY/.claude/CLAUDE.md"

# ── Claude: appends to existing file ─────────────────────────────────────────

echo ""
echo "claude --project: appends to pre-existing .claude/CLAUDE.md"
mkdir -p "$PROJECT_EXISTING/.claude"
echo "# My project rules" > "$PROJECT_EXISTING/.claude/CLAUDE.md"
run_project_in "$PROJECT_EXISTING" claude --project --skills go >/dev/null

check_true "existing content preserved" grep -q "My project rules" "$PROJECT_EXISTING/.claude/CLAUDE.md"
check_true "skill appended"             grep -qF "agentguard:skill:go" "$PROJECT_EXISTING/.claude/CLAUDE.md"

# ── Codex: creates AGENTS.md ──────────────────────────────────────────────────

echo ""
echo "codex --project: creates AGENTS.md with skill"
run_project_in "$PROJECT_CODEX" codex --project --skills go >/dev/null

check_true  "creates AGENTS.md"            test -f "$PROJECT_CODEX/AGENTS.md"
check_true  "skill sentinel present"       grep -qF "agentguard:skill:go" "$PROJECT_CODEX/AGENTS.md"
check_false "global AGENTS.md not written" test -f "$FAKE_HOME/AGENTS.md"

# ── Kiro: prints warning, no files written ────────────────────────────────────

echo ""
echo "kiro --project: prints warning, exits 0"
kiro_out=$(run_project_in "$PROJECT_KIRO" kiro --project --skills go)
if echo "$kiro_out" | grep -q "not support"; then
  printf "  PASS  warning printed\n"; ((pass++))
else
  printf "  FAIL  warning not printed\n"; ((fail++))
fi
check_false "no KIRO.md written"        test -f "$PROJECT_KIRO/KIRO.md"
check_false "no global KIRO.md written" test -f "$FAKE_HOME/.kiro/KIRO.md"

# ── Cursor: --project runs full install (cursor is always project-local) ──────

echo ""
echo "cursor --project: runs full install (hooks + AGENTS.md + skills)"
run_project_in "$PROJECT_CURSOR" cursor --project --skills go >/dev/null

check_true  "creates AGENTS.md"          test -f "$PROJECT_CURSOR/AGENTS.md"
check_true  "skill sentinel present"     grep -q "agentguard:skill:go" "$PROJECT_CURSOR/AGENTS.md"
check_true  "hooks written (full install)" test -d "$PROJECT_CURSOR/.cursor/hooks"
check_false "no global AGENTS.md"        test -f "$FAKE_HOME/AGENTS.md"

# ── all --project: claude + codex succeed, kiro warns ─────────────────────────

echo ""
echo "all --project: claude and codex install, kiro warns"
run_project_in "$PROJECT_ALL" all --project --skills go >/dev/null

check_true  "all: .claude/CLAUDE.md created"  test -f "$PROJECT_ALL/.claude/CLAUDE.md"
check_true  "all: AGENTS.md created"          test -f "$PROJECT_ALL/AGENTS.md"
check_false "all: no hooks written"           test -d "$FAKE_HOME/.claude/hooks"
check_false "all: no cursor hooks written"    test -d "$PROJECT_ALL/.cursor/hooks"  # cursor excluded from all --project

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
