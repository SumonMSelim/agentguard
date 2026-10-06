#!/bin/bash
# tests/upgrade.sh — agentguard version checker and upgrade tests
#
# Tests:
#   - VERSION file exists and is parseable
#   - track_installed_agent writes to config on install
#   - untrack_installed_agent removes agent from config on uninstall
#   - agentguard upgrade --dry-run reports what it would do
#   - sequential installs keep every tracked agent (issue #59)
#   - upgrade keeps tracked agents and protected branches (issue #59)
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
echo "agent tracking — install all tracks global agents (not cursor)"
run_install all
for agent in claude kiro codex gemini; do
  if grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q "$agent"; then
    printf "  PASS  %s tracked after install all\n" "$agent"
    ((pass++))
  else
    printf "  FAIL  %s not tracked after install all\n" "$agent"
    ((fail++))
  fi
done
# cursor is project-local — must NOT be tracked
if ! grep 'AGENTGUARD_INSTALLED_AGENTS=' "$CFG" | grep -q 'cursor'; then
  printf "  PASS  cursor not tracked (project-local)\n"
  ((pass++))
else
  printf "  FAIL  cursor should not be in tracked agents\n"
  ((fail++))
fi

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
# claude is already tracked in FAKE_HOME from the tracking tests above.

echo ""
echo "upgrade --dry-run"
check_output_contains \
  "upgrade dry-run reports would pull" \
  "Would run:" \
  bash -c "cd \"$FAKE_PROJECT\" && HOME=\"$FAKE_HOME\" bash \"$SCRIPT_DIR/install.sh\" upgrade --dry-run"

check_output_contains \
  "upgrade dry-run reports would reinstall" \
  "Would uninstall" \
  bash -c "cd \"$FAKE_PROJECT\" && HOME=\"$FAKE_HOME\" bash \"$SCRIPT_DIR/install.sh\" upgrade --dry-run"

# ── sequential installs keep tracked agents (issue #59) ──────────────────────

tracked_agents() {
  grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$1" | tail -n1 \
    | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//'
}
protected_branches() {
  grep -E '^AGENTGUARD_PROTECTED_BRANCHES=' "$1" | tail -n1 \
    | sed -E 's/^AGENTGUARD_PROTECTED_BRANCHES=//; s/^"//; s/"$//'
}

echo ""
echo "agent tracking — sequential installs keep every agent"
SEQ_HOME=$(mktemp -d)
(cd "$FAKE_PROJECT" && HOME="$SEQ_HOME" bash "$SCRIPT_DIR/install.sh" claude </dev/null) >/dev/null 2>&1
(cd "$FAKE_PROJECT" && HOME="$SEQ_HOME" bash "$SCRIPT_DIR/install.sh" kiro   </dev/null) >/dev/null 2>&1
seq_tracked=$(tracked_agents "$SEQ_HOME/.agentguard/config")
if [[ "$seq_tracked" == "claude kiro" ]]; then
  printf "  PASS  claude then kiro install tracks both agents\n"
  ((pass++))
else
  printf "  FAIL  expected 'claude kiro' tracked, got '%s'\n" "$seq_tracked"
  ((fail++))
fi
rm -rf "$SEQ_HOME"

# ── upgrade keeps tracked agents and protected branches (issue #59) ───────────
# Upgrade runs git pull in its own dir, so run it from a throwaway clone.

echo ""
echo "upgrade — keeps tracked agents and protected branches"
UP_HOME=$(mktemp -d)
UP_ORIGIN=$(mktemp -d)
UP_CLONE="$(mktemp -d)/clone"
(cd "$SCRIPT_DIR" && tar --exclude=.git -cf - .) | (cd "$UP_ORIGIN" && tar -xf -)
git -C "$UP_ORIGIN" init -q
git -C "$UP_ORIGIN" add -A -f   # -f: agents/*/AGENTS.md matches .gitignore
git -C "$UP_ORIGIN" -c user.name=test -c user.email=test@example.com commit -qm init
git clone -q "$UP_ORIGIN" "$UP_CLONE"
for agent in claude codex kiro grok gemini; do
  (cd "$FAKE_PROJECT" && HOME="$UP_HOME" bash "$UP_CLONE/install.sh" "$agent" </dev/null) >/dev/null 2>&1
done
(cd "$FAKE_PROJECT" && HOME="$UP_HOME" bash "$UP_CLONE/install.sh" cursor --user </dev/null) >/dev/null 2>&1
# Simulate an older user-level hooks.json: a user hook, and no agentguard preToolUse entry.
jq '.hooks.preToolUse = [{"command":"./hooks/mine.sh"}]' "$UP_HOME/.cursor/hooks.json" > "$UP_HOME/hj.tmp" \
  && mv "$UP_HOME/hj.tmp" "$UP_HOME/.cursor/hooks.json"
# A previous install saved a custom value; non-TTY installs reuse it as default.
sed -i.bak 's/^AGENTGUARD_PROTECTED_BRANCHES=.*/AGENTGUARD_PROTECTED_BRANCHES="main,master,release"/' \
  "$UP_HOME/.agentguard/config" && rm -f "$UP_HOME/.agentguard/config.bak"
before_tracked=$(tracked_agents "$UP_HOME/.agentguard/config")
up_out=$(cd "$FAKE_PROJECT" && HOME="$UP_HOME" bash "$UP_CLONE/install.sh" upgrade </dev/null 2>&1) || true
after_tracked=$(tracked_agents "$UP_HOME/.agentguard/config")
after_branches=$(protected_branches "$UP_HOME/.agentguard/config")
if [[ "$before_tracked" == "claude codex kiro grok gemini cursor-user" && "$after_tracked" == "$before_tracked" ]]; then
  printf "  PASS  upgrade keeps all tracked agents\n"
  ((pass++))
else
  printf "  FAIL  tracked agents before '%s', after upgrade '%s'\n" "$before_tracked" "$after_tracked"
  ((fail++))
fi
if [[ "$after_branches" == "main,master,release" ]]; then
  printf "  PASS  upgrade keeps custom protected branches\n"
  ((pass++))
else
  printf "  FAIL  protected branches after upgrade: '%s'\n" "$after_branches"
  ((fail++))
fi
if ! echo "$up_out" | grep -qF "using default protected branches"; then
  printf "  PASS  upgrade child installs skip the protected-branches prompt\n"
  ((pass++))
else
  printf "  FAIL  upgrade child installs ran the protected-branches prompt\n"
  ((fail++))
fi
if [[ -f "$UP_HOME/.codex/AGENTS.md" && -f "$UP_HOME/.codex/hooks.json" ]]; then
  printf "  PASS  upgrade reinstalls codex under ~/.codex\n"
  ((pass++))
else
  printf "  FAIL  codex AGENTS.md or hooks.json missing under ~/.codex after upgrade\n"
  ((fail++))
fi
if [[ -f "$UP_HOME/.gemini/GEMINI.md" ]] && jq -e '[.hooks.BeforeTool[].hooks[].command] | any(test("block-env.sh"))' \
     "$UP_HOME/.gemini/settings.json" >/dev/null 2>&1; then
  printf "  PASS  upgrade reinstalls gemini under ~/.gemini\n"
  ((pass++))
else
  printf "  FAIL  gemini GEMINI.md or settings.json hooks missing under ~/.gemini after upgrade\n"
  ((fail++))
fi
if jq -e --arg h "$UP_HOME" '[.hooks.preToolUse[].command] == ["./hooks/mine.sh", ($h + "/.cursor/hooks/block-env-read.sh")]' \
     "$UP_HOME/.cursor/hooks.json" >/dev/null 2>&1; then
  printf "  PASS  upgrade refreshes user-level cursor hooks.json, keeps user hook\n"
  ((pass++))
else
  printf "  FAIL  user-level cursor hooks.json not refreshed by upgrade\n"
  ((fail++))
fi
rm -rf "$UP_HOME" "$UP_ORIGIN" "$(dirname "$UP_CLONE")"

# ── upgrade keeps user content and selected skills ────────────────────────────
# upgrade runs `git pull`, so run it from a throwaway clone of the working tree.

echo ""
echo "upgrade — keeps user CLAUDE.md content and re-applies selected skills"
UP_HOME=$(mktemp -d); UP_SRC=$(mktemp -d); UP_CLONE=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJECT" "$UP_HOME" "$UP_SRC" "$UP_CLONE"' EXIT
cp -R "$SCRIPT_DIR/." "$UP_SRC"
rm -rf "$UP_SRC/.git"
git -C "$UP_SRC" init -q
git -C "$UP_SRC" add -A -f   # -f: agents/*/AGENTS.md matches .gitignore
git -C "$UP_SRC" -c user.name=test -c user.email=test@example.com commit -qm init
git clone -q "$UP_SRC" "$UP_CLONE/agentguard"

mkdir -p "$UP_HOME/.claude"
printf 'MY OWN RULES\n' > "$UP_HOME/.claude/CLAUDE.md"
(cd "$FAKE_PROJECT" && HOME="$UP_HOME" bash "$UP_CLONE/agentguard/install.sh" claude --skills go) >/dev/null 2>&1
(cd "$FAKE_PROJECT" && HOME="$UP_HOME" bash "$UP_CLONE/agentguard/install.sh" upgrade) >/dev/null 2>&1

check_true "custom line present after upgrade"  grep -qxF 'MY OWN RULES' "$UP_HOME/.claude/CLAUDE.md"
check_true "go skill present after upgrade"     grep -qF '<!-- agentguard:skill:go -->' "$UP_HOME/.claude/CLAUDE.md"

# ── .deb upgrade checksum verification (#87) ──────────────────────────────────
# Load only verify_sha256 from install.sh, with fail/ok stubs. The function is
# cut out here, not inside bash -c: bash 3.2 (macOS) brace-expands "{/,/^}"
# in a double-quoted $(...).

echo ""
echo "verify_sha256 — .deb upgrade checksum check"
SUM_DIR=$(mktemp -d)
printf 'package bytes\n' > "$SUM_DIR/agentguard_9.9.9_all.deb"
good=$(cd "$SUM_DIR" && { sha256sum agentguard_9.9.9_all.deb 2>/dev/null || shasum -a 256 agentguard_9.9.9_all.deb; })
printf '%s\n' "$good" > "$SUM_DIR/good.sums"
printf '%064d  agentguard_9.9.9_all.deb\n' 0 > "$SUM_DIR/bad.sums"
printf '%064d  other.deb\n' 0 > "$SUM_DIR/other.sums"
sed -n '/^verify_sha256() {/,/^}/p' "$SCRIPT_DIR/install.sh" > "$SUM_DIR/verify_sha256.sh"
run_verify() {
  bash -c '
    fail() { echo "$*" >&2; exit 1; }
    ok()   { :; }
    source "$1"
    verify_sha256 "$2" "$3" agentguard_9.9.9_all.deb
  ' _ "$SUM_DIR/verify_sha256.sh" "$SUM_DIR/agentguard_9.9.9_all.deb" "$1"
}
check_true  "matching checksum passes"      run_verify "$SUM_DIR/good.sums"
check_false "checksum mismatch aborts"      run_verify "$SUM_DIR/bad.sums"
check_false "asset missing from sums aborts" run_verify "$SUM_DIR/other.sums"
check_false "missing sums file aborts"      run_verify "$SUM_DIR/absent.sums"
rm -rf "$SUM_DIR"

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
