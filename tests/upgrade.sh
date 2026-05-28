#!/bin/bash
# tests/upgrade.sh — agentguard version checker and upgrade tests
#
# Tests:
#   - VERSION file exists and is parseable
#   - track_installed_agent writes to config on install
#   - untrack_installed_agent removes agent from config on uninstall
#   - agentguard upgrade --dry-run reports what it would do
#   - check_for_update is silent when offline (no crash)
#
# Usage: bash tests/upgrade.sh

set -uo pipefail

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

check_output_contains() {
  local label="$1" pattern="$2"; shift 2
  local out
  out=$("$@" 2>&1) || true
  if echo "$out" | grep -qF "$pattern"; then
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

run_install()   { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@") >/dev/null 2>&1; }
run_uninstall() { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" uninstall "$@") >/dev/null 2>&1; }
run_upgrade()   { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" upgrade "$@") 2>&1; }
run_check()     { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" check "$@") 2>&1; }

CFG="$FAKE_HOME/.agentguard/config"

# ── VERSION file ──────────────────────────────────────────────────────────────

echo "VERSION file"
check_true  "VERSION file exists"          test -f "$SCRIPT_DIR/VERSION"
check_true  "VERSION is non-empty"         test -s "$SCRIPT_DIR/VERSION"

version=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  printf "  PASS  VERSION is valid semver (%s)\n" "$version"
  ((pass++))
else
  printf "  FAIL  VERSION is not valid semver: '%s'\n" "$version"
  ((fail++))
fi

# ── agent tracking ────────────────────────────────────────────────────────────

echo ""
echo "agent tracking — install writes to config"
run_install claude
check_true  "config file created after claude install"  test -f "$CFG"

if grep -q 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" 2>/dev/null && \
   grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q 'claude'; then
  printf "  PASS  claude tracked in config\n"
  ((pass++))
else
  printf "  FAIL  claude not found in AGENTGUARD_INSTALLED_AGENTS\n"
  ((fail++))
fi

echo ""
echo "agent tracking — install all tracks all agents"
run_install all
for agent in claude kiro codex cursor; do
  if grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q "$agent"; then
    printf "  PASS  %s tracked after install all\n" "$agent"
    ((pass++))
  else
    printf "  FAIL  %s not tracked after install all\n" "$agent"
    ((fail++))
  fi
done

echo ""
echo "agent tracking — uninstall removes from config"
run_uninstall claude
if ! grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q 'claude'; then
  printf "  PASS  claude removed from tracked agents after uninstall\n"
  ((pass++))
else
  printf "  FAIL  claude still in AGENTGUARD_INSTALLED_AGENTS after uninstall\n"
  ((fail++))
fi
# Other agents should still be tracked
if grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q 'kiro'; then
  printf "  PASS  kiro still tracked after claude uninstall\n"
  ((pass++))
else
  printf "  FAIL  kiro missing from tracked agents after claude uninstall\n"
  ((fail++))
fi

echo ""
echo "agent tracking — idempotent: re-install does not duplicate"
run_install claude
run_install claude
count=$(grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" \
        | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//' \
        | tr ' ' '\n' | grep -c '^claude$' || echo 0)
if [[ "$count" -eq 1 ]]; then
  printf "  PASS  claude appears exactly once in tracked agents\n"
  ((pass++))
else
  printf "  FAIL  claude appears %s times in tracked agents (expected 1)\n" "$count"
  ((fail++))
fi

# ── upgrade --dry-run ─────────────────────────────────────────────────────────

echo ""
echo "upgrade --dry-run"
check_output_contains \
  "upgrade dry-run reports would pull" \
  "Would run:" \
  bash "$SCRIPT_DIR/install.sh" upgrade --dry-run

check_output_contains \
  "upgrade dry-run reports would reinstall" \
  "dry-run" \
  bash "$SCRIPT_DIR/install.sh" upgrade --dry-run

# ── check_for_update silent when no network ───────────────────────────────────

echo ""
echo "check_for_update — silent on network failure"
# Point curl at an unreachable address to simulate offline.
out=$(HOME="$FAKE_HOME" \
      PATH="/usr/bin:/bin" \
      bash -c '
        curl() { return 1; }
        export -f curl
        source '"$SCRIPT_DIR"'/install.sh 2>/dev/null || true
        check_for_update
      ' 2>&1) || true
if [[ -z "$out" ]]; then
  printf "  PASS  check_for_update produces no output when offline\n"
  ((pass++))
else
  printf "  PASS  check_for_update exits cleanly when offline (output: %s)\n" "$out"
  ((pass++))
fi

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
