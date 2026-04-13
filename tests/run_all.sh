#!/bin/bash
# tests/run_all.sh — runs all agentguard test suites
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
overall=0

run_suite() {
  local name="$1" script="$2"
  echo "══════════════════════════════════════════════"
  echo " $name"
  echo "══════════════════════════════════════════════"
  bash "$script" || overall=1
  echo ""
}

run_suite "Claude" "$DIR/claude.sh"
run_suite "Kiro"   "$DIR/kiro.sh"

exit $overall
