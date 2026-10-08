#!/bin/bash
# tests/doctor.sh — agentguard doctor command test suite
#
# Installs Claude into a fake HOME, puts stub agent binaries on a minimal PATH
# and checks what `agentguard doctor` reports and how it exits.
#
# Requirements: bash, jq

set -uo pipefail
# Note: -e intentionally omitted — ((pass++)) exits 1 when result is zero under set -e.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

FAKE_HOME=$(mktemp -d)
FAKE_PROJECT=$(mktemp -d)
EMPTY_HOME=$(mktemp -d)
STUB_DIR=$(mktemp -d)
TOOLS_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJECT" "$EMPTY_HOME" "$STUB_DIR" "$TOOLS_DIR"' EXIT

# Stub agent CLIs first, then jq, then system dirs: no real agent binary is found.
ln -s "$(command -v jq)" "$TOOLS_DIR/jq"
DOCTOR_PATH="$STUB_DIR:$TOOLS_DIR:/usr/bin:/bin"

run_doctor() { (cd "$FAKE_PROJECT" && PATH="$DOCTOR_PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" doctor "$@") 2>&1; }

# check_has <label> <needle> <doctor args...> — output contains <needle>.
check_has() {
  local label="$1" needle="$2" got; shift 2
  got=$(run_doctor "$@")
  if [[ "$got" == *"$needle"* ]]; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n        want: %s\n        got:\n%s\n" "$label" "$needle" "$got"
    ((fail++))
  fi
}

# check_lacks <label> <needle> <doctor args...> — output does not contain <needle>.
check_lacks() {
  local label="$1" needle="$2" got; shift 2
  got=$(run_doctor "$@")
  if [[ "$got" != *"$needle"* ]]; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n        unwanted: %s\n" "$label" "$needle"
    ((fail++))
  fi
}

# check_exit <label> <expected code> <command...>
check_exit() {
  local label="$1" want="$2" got; shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [[ "$got" -eq "$want" ]]; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s (exit %s, want %s)\n" "$label" "$got" "$want"
    ((fail++))
  fi
}

(cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" claude) >/dev/null 2>&1

printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"

# Far past / far future timestamps keep the 24h window independent of the clock.
LOG="$FAKE_HOME/.claude/audit.log"
{
  echo '2000-01-01T00:00:00Z BLOCKED hook=block-env.sh tool=Bash cat .env'
  echo '2999-01-01T00:00:01Z BLOCKED hook=block-env.sh tool=Bash cat .env'
  echo '2999-01-01T00:00:02Z tool=Bash ls'
  echo '2999-01-01T00:00:03Z BLOCKED hook=block-main-branch.sh tool=Bash git push origin main'
} > "$LOG"
sum_before=$(cksum "$LOG")

echo "doctor — global"
check_has "agentguard version shown" "agentguard version: $(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")" claude
check_has "jq found"                 "[PASS]    jq: $TOOLS_DIR/jq" claude
check_has "tracked agents listed"    "tracked agents: claude" claude
check_has "no disabled dirs"         "disabled dirs: none" claude

echo ""
echo "doctor — healthy install"
check_has  "install check passes"      "[PASS]    install check: 'agentguard check claude' passes" claude
check_has  "agent binary found"        "[PASS]    agent binary: $STUB_DIR/claude" claude
if PATH="$DOCTOR_PATH" command -v timeout >/dev/null 2>&1; then
  check_has "agent version shown"      "$STUB_DIR/claude (9.9.9 (Claude Code))" claude
fi
check_has  "log size and last entry"   "($(wc -c < "$LOG" | tr -d '[:space:]') bytes, last entry 2999-01-01T00:00:03Z" claude
check_has  "blocked count in 24h"      "2 blocked in the last 24h" claude
check_lacks "no failures"              "[FAIL]" claude
check_exit "healthy install exits 0"   0 run_doctor claude
check_has  "default is tracked agents" "[PASS]    install check: 'agentguard check claude' passes"
check_lacks "default skips untracked"  "install check: 'agentguard check codex'"
check_exit "default exits 0"           0 run_doctor

echo ""
echo "doctor — warnings do not fail"
rm "$STUB_DIR/claude"
check_has  "missing binary warns"      "[WARN]    agent binary: not found on PATH (looked for: claude)" claude
check_exit "missing binary exits 0"    0 run_doctor claude
mv "$LOG" "$LOG.keep"
check_has  "missing log warns"         "[WARN]    activity: no audit log yet at $LOG" claude
check_exit "missing log exits 0"       0 run_doctor claude
mv "$LOG.keep" "$LOG"
mkdir -p "$FAKE_HOME/.agentguard"
printf '# comment\n%s\n' "$FAKE_PROJECT" > "$FAKE_HOME/.agentguard/disabled-dirs"
check_has  "disabled dir warns"        "[WARN]    disabled dir: $FAKE_PROJECT" claude
check_exit "disabled dir exits 0"      0 run_doctor claude
rm "$FAKE_HOME/.agentguard/disabled-dirs"

echo ""
echo "doctor — failures"
check_has  "uninstalled agent fails"   "[FAIL]    install check:" codex
check_has  "failure details shown"     "[MISSING]" codex
check_has  "codex activation hint"     "hint: Codex runs these hooks only after you approve them with /hooks" codex
check_exit "uninstalled agent exits 1" 1 run_doctor codex
rm "$FAKE_HOME/.claude/hooks/block-env.sh"
check_exit "broken install exits 1"    1 run_doctor claude
check_exit "nothing tracked: all agents, exits 1" 1 \
  bash -c 'cd "$1" && PATH="$2" HOME="$1" bash "$3/install.sh" doctor' _ "$EMPTY_HOME" "$DOCTOR_PATH" "$SCRIPT_DIR"
got=$( (cd "$EMPTY_HOME" && PATH="$DOCTOR_PATH" HOME="$EMPTY_HOME" bash "$SCRIPT_DIR/install.sh" doctor) 2>&1)
if [[ "$got" == *"tracked agents: none"* && "$got" == *"run 'agentguard antigravity' to fix"* ]]; then
  printf "  PASS  %s\n" "nothing tracked checks every agent"; ((pass++))
else
  printf "  FAIL  %s\n" "nothing tracked checks every agent"; ((fail++))
fi
check_exit "unknown agent exits 1"     1 run_doctor nope

echo ""
echo "doctor — read only"
if [[ "$sum_before" == "$(cksum "$LOG")" ]]; then
  printf "  PASS  %s\n" "audit log not modified"; ((pass++))
else
  printf "  FAIL  %s\n" "audit log not modified"; ((fail++))
fi

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
