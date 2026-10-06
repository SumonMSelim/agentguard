#!/bin/bash
# tests/install.sh — agentguard install edge-case suite
#
# Covers what uninstall.sh and upgrade.sh do not: `claude` then `all`,
# re-install idempotency, settings.json merge with odd shapes, a HOME path
# with a space, Cursor hooks.json, and a full install/uninstall round trip
# that must leave HOME as it was.
#
# Usage: bash tests/install.sh
# Requirements: bash, jq

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

jq_true() {
  local label="$1" query="$2" file="$3"
  check_true "$label" jq -e "$query" "$file"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Each scenario gets a fresh HOME and project dir.
fresh() {
  rm -rf "${TMP:?}/home" "${TMP:?}/proj"
  FAKE_HOME="$TMP/home"; FAKE_PROJECT="$TMP/proj"
  mkdir -p "$FAKE_HOME" "$FAKE_PROJECT"
  S="$FAKE_HOME/.claude/settings.json"
}
run_install()   { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" "$@" </dev/null) >/dev/null 2>&1; }
run_uninstall() { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" uninstall "$@" </dev/null) >/dev/null 2>&1; }

# Every agentguard hook command appears exactly once in settings.json.
no_dup_hooks() {
  jq -e '[.hooks[][]?.hooks[]?.command | select(test("/\\.claude/hooks/"))] | (length > 0) and (length == (unique | length))' "$1"
}
no_dup_perms() {
  jq -e '[.permissions | (.allow, .ask, .deny)[]? ] | length == (unique | length)' "$1"
}
same_json() { diff <(jq -S . "$1") <(jq -S . "$2"); }
# Listing of every file under a dir with its content hash, minus backups
# (uninstall keeps *.bak.<ts>) and settings.json (compared as JSON).
tree_sig() {
  (cd "$1" && command find . -type f ! -name '*.bak.*' ! -name settings.json | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done)
}

# ── sequential installs ───────────────────────────────────────────────────────

echo "install claude, then install all"
fresh
run_install claude
check_true  "install all after claude succeeds"   run_install all
check_true  "settings.json is valid JSON"         jq empty "$S"
check_true  "no duplicate agentguard hooks"       no_dup_hooks "$S"
check_true  "no duplicate permission rules"       no_dup_perms "$S"
check_true  "one karpathy skill sentinel" \
  test "$(grep -c '<!-- agentguard:skill:karpathy-guidelines -->' "$FAKE_HOME/.claude/CLAUDE.md")" -eq 1
check_true  "kiro installed"                      test -f "$FAKE_HOME/.kiro/agents/agentguard.json"
check_true  "codex installed"                     test -f "$FAKE_HOME/.codex/hooks.json"
check_true  "cursor installed in project"         test -f "$FAKE_PROJECT/.cursor/hooks.json"
check_true  "claude still tracked" \
  grep -qE '^AGENTGUARD_INSTALLED_AGENTS=.*claude' "$FAKE_HOME/.agentguard/config"

# ── re-install idempotency ────────────────────────────────────────────────────

echo ""
echo "re-install is idempotent"
fresh
run_install claude
cp "$S" "$TMP/settings.1"
cp "$FAKE_HOME/.claude/CLAUDE.md" "$TMP/claude.1"
run_install claude
check_true  "settings.json unchanged by second install"  same_json "$TMP/settings.1" "$S"
check_true  "CLAUDE.md unchanged by second install"      diff "$TMP/claude.1" "$FAKE_HOME/.claude/CLAUDE.md"
run_install codex
cp "$FAKE_HOME/.codex/hooks.json" "$TMP/codex.1"
run_install codex
check_true  "codex hooks.json unchanged by second install" same_json "$TMP/codex.1" "$FAKE_HOME/.codex/hooks.json"

# ── settings.json shapes ──────────────────────────────────────────────────────

# seed <json> — writes a user settings.json into a fresh HOME.
seed() { fresh; mkdir -p "$FAKE_HOME/.claude"; printf '%s\n' "$1" > "$S"; cp "$S" "$TMP/before.json"; }

echo ""
echo "merge — no permissions key"
seed '{"model":"opus"}'
check_true  "install succeeds"                    run_install claude
jq_true     "deny rules added"                    '.permissions.deny | length > 0' "$S"
jq_true     "model kept"                          '.model == "opus"' "$S"

echo ""
echo "merge — matcher-less PreToolUse block"
seed '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}'
check_true  "install succeeds"                    run_install claude
jq_true     "user hook kept"                      '[.hooks.PreToolUse[].hooks[].command] | index("echo mine") != null' "$S"
jq_true     "our Bash hooks added"                '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command] | any(test("block-env.sh"))' "$S"
check_true  "no duplicate agentguard hooks"       no_dup_hooks "$S"
run_uninstall claude
check_true  "uninstall restores the file"         same_json "$TMP/before.json" "$S"

echo ""
echo "merge — user hook order kept"
seed '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"z-first.sh"},{"type":"command","command":"a-second.sh"}]}]}}'
run_install claude
jq_true     "user hooks keep their order"         '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(test("^[za]-"))] == ["z-first.sh","a-second.sh"]' "$S"
run_uninstall claude
check_true  "uninstall restores the file"         same_json "$TMP/before.json" "$S"

echo ""
echo "merge — invalid JSON is refused and left unchanged"
seed '{"model":"opus",}'
cp "$S" "$TMP/invalid.json"
check_false "install fails"                       run_install claude
check_true  "file byte-identical"                 cmp "$TMP/invalid.json" "$S"
check_false "uninstall fails"                     run_uninstall claude
check_true  "file still byte-identical"           cmp "$TMP/invalid.json" "$S"

# ── HOME with a space ─────────────────────────────────────────────────────────

echo ""
echo "HOME path with a space"
fresh
FAKE_HOME="$TMP/my home"; S="$FAKE_HOME/.claude/settings.json"
mkdir -p "$FAKE_HOME"
check_true  "install claude succeeds"             run_install claude
check_true  "settings.json is valid JSON"         jq empty "$S"
check_true  "hooks installed"                     test -f "$FAKE_HOME/.claude/hooks/block-env.sh"
check_true  "uninstall claude succeeds"           run_uninstall claude
check_false "hooks removed"                       test -f "$FAKE_HOME/.claude/hooks/block-env.sh"
rm -rf "$FAKE_HOME"

# ── Cursor hooks.json ─────────────────────────────────────────────────────────

echo ""
echo "cursor — hooks.json points at installed scripts"
fresh
run_install cursor
H="$FAKE_PROJECT/.cursor/hooks.json"
check_true  "hooks.json is valid JSON"            jq empty "$H"
missing=""
while IFS= read -r cmd; do
  script=$(grep -oE '[^[:space:]"]+\.sh' <<<"$cmd" | head -n1)
  [[ -f "$FAKE_PROJECT/$script" ]] || missing="$missing $script"
done < <(jq -r '.. | .command? // empty' "$H")
check_true  "every hook command script exists"   test -z "$missing"

# ── full round trip ───────────────────────────────────────────────────────────

echo ""
echo "round trip — claude, all, uninstall all leaves HOME as it was"
seed '{"model":"opus","permissions":{"allow":["WebSearch"]}}'
printf 'MY OWN RULES\n' > "$FAKE_HOME/.claude/CLAUDE.md"
tree_sig "$FAKE_HOME" > "$TMP/sig.before"
run_install claude
run_install all
run_uninstall all
tree_sig "$FAKE_HOME" > "$TMP/sig.after"
check_true  "same files and contents after uninstall all" diff "$TMP/sig.before" "$TMP/sig.after"
check_true  "settings.json restored"              same_json "$TMP/before.json" "$S"
check_false "cursor hooks.json removed"           test -e "$FAKE_PROJECT/.cursor/hooks.json"

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
