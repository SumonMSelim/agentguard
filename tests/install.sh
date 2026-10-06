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
check_true  "gemini installed"                    test -f "$FAKE_HOME/.gemini/settings.json"
check_true  "copilot installed"                   test -f "$FAKE_HOME/.copilot/hooks/agentguard.json"
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

# ── Gemini settings.json ──────────────────────────────────────────────────────

echo ""
echo "gemini — merge into user settings.json"
fresh
G="$FAKE_HOME/.gemini/settings.json"
mkdir -p "$FAKE_HOME/.gemini"
printf '%s\n' '{"model":{"name":"gemini-2.5-pro"},"general":{"vimMode":true},"hooksConfig":{"notifications":false},"hooks":{"BeforeTool":[{"matcher":"write_file","hooks":[{"type":"command","command":"my-check.sh"}]}],"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"hello.sh"}]}]}}' > "$G"
cp "$G" "$TMP/gemini.before"
check_true  "install gemini succeeds"             run_install gemini
check_true  "settings.json is valid JSON"         jq empty "$G"
jq_true     "user keys kept"                      '.model.name == "gemini-2.5-pro" and .general.vimMode and .hooksConfig == {"notifications":false}' "$G"
jq_true     "user hooks kept"                     '[.hooks[][].hooks[].command] | index("my-check.sh") != null and index("hello.sh") != null' "$G"
jq_true     "our shell hooks added"               '[.hooks.BeforeTool[] | select(.matcher == "run_shell_command") | .hooks[].command] | any(test("/\\.gemini/hooks/block-env.sh$"))' "$G"
jq_true     "our audit hook added"                '[.hooks.AfterTool[].hooks[].command] | any(test("audit-log.sh"))' "$G"
check_true  "hook scripts installed"              test -x "$FAKE_HOME/.gemini/hooks/block-env-read.sh"
check_true  "GEMINI.md installed"                 grep -qF '<!-- agentguard:created -->' "$FAKE_HOME/.gemini/GEMINI.md"
check_true  "gemini tracked" \
  grep -qE '^AGENTGUARD_INSTALLED_AGENTS=.*gemini' "$FAKE_HOME/.agentguard/config"
cp "$G" "$TMP/gemini.1"
run_install gemini
check_true  "settings.json unchanged by second install" same_json "$TMP/gemini.1" "$G"
check_true  "one karpathy skill sentinel" \
  test "$(grep -c '<!-- agentguard:skill:karpathy-guidelines -->' "$FAKE_HOME/.gemini/GEMINI.md")" -eq 1
check_true  "uninstall gemini succeeds"           run_uninstall gemini
check_true  "uninstall restores settings.json"    same_json "$TMP/gemini.before" "$G"
check_false "GEMINI.md removed"                   test -e "$FAKE_HOME/.gemini/GEMINI.md"
check_false "hooks dir removed"                   test -e "$FAKE_HOME/.gemini/hooks"

echo ""
echo "gemini — legacy hooks.enabled key survives uninstall"
fresh
mkdir -p "$FAKE_HOME/.gemini"
printf '%s\n' '{"hooks":{"enabled":true,"disabled":["x"]}}' > "$G"
cp "$G" "$TMP/gemini.before"
run_install gemini
jq_true     "legacy keys kept on install"         '.hooks.enabled == true and .hooks.disabled == ["x"]' "$G"
run_uninstall gemini
check_true  "uninstall restores settings.json"    same_json "$TMP/gemini.before" "$G"

echo ""
echo "gemini — no settings.json: created, then removed on uninstall"
fresh
run_install gemini
check_true  "settings.json created"               jq empty "$G"
run_uninstall gemini
check_false "settings.json removed"               test -e "$G"

echo ""
echo "gemini — invalid settings.json is refused and left unchanged"
fresh
mkdir -p "$FAKE_HOME/.gemini"
printf '{"model":{},}\n' > "$G"
cp "$G" "$TMP/invalid.json"
check_false "install fails"                       run_install gemini
check_true  "file byte-identical"                 cmp "$TMP/invalid.json" "$G"
run_uninstall gemini
check_true  "file still byte-identical"           cmp "$TMP/invalid.json" "$G"

# ── GitHub Copilot CLI ────────────────────────────────────────────────────────

echo ""
echo "copilot — own hooks file next to the user's, instructions kept"
fresh
C="$FAKE_HOME/.copilot"
mkdir -p "$C/hooks"
printf '%s\n' '{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"./mine.sh"}]}}' > "$C/hooks/mine.json"
cp "$C/hooks/mine.json" "$TMP/mine.before"
printf 'MY COPILOT RULES\n' > "$C/copilot-instructions.md"
chmod 600 "$C/copilot-instructions.md"
check_true  "install copilot succeeds"            run_install copilot --skills go
check_true  "agentguard.json is our config"       cmp "$SCRIPT_DIR/agents/copilot/hooks.json" "$C/hooks/agentguard.json"
jq_true     "bash hooks use ~/.copilot/hooks"     '[.hooks.preToolUse[].bash] | all(startswith("bash ~/.copilot/hooks/"))' "$C/hooks/agentguard.json"
check_true  "hook scripts installed"              test -x "$C/hooks/block-env-read.sh"
check_true  "user hooks file untouched"           cmp "$TMP/mine.before" "$C/hooks/mine.json"
check_true  "user instructions kept"              grep -qx 'MY COPILOT RULES' "$C/copilot-instructions.md"
check_true  "skill appended"                      grep -qF '<!-- agentguard:skill:go -->' "$C/copilot-instructions.md"
check_true  "copilot tracked" \
  grep -qE '^AGENTGUARD_INSTALLED_AGENTS=.*copilot' "$FAKE_HOME/.agentguard/config"
run_install copilot --skills go
check_true  "one skill sentinel after re-install" \
  test "$(grep -c '<!-- agentguard:skill:go -->' "$C/copilot-instructions.md")" -eq 1
check_true  "uninstall copilot succeeds"          run_uninstall copilot
check_false "agentguard.json removed"             test -e "$C/hooks/agentguard.json"
check_false "hook scripts removed"                test -e "$C/hooks/block-env.sh"
check_true  "user hooks file kept"                cmp "$TMP/mine.before" "$C/hooks/mine.json"
check_true  "user instructions kept"              grep -qx 'MY COPILOT RULES' "$C/copilot-instructions.md"
check_false "skill section stripped"              grep -qF 'agentguard:skill' "$C/copilot-instructions.md"
check_true  "instructions 600 after skill strip"  test "$(stat -c %a "$C/copilot-instructions.md" 2>/dev/null || stat -f %Lp "$C/copilot-instructions.md")" = 600

echo ""
echo "copilot — fresh install creates and removes everything"
fresh
run_install copilot
check_true  "instructions created with marker"    grep -qF '<!-- agentguard:created -->' "$FAKE_HOME/.copilot/copilot-instructions.md"
run_uninstall copilot
check_false "instructions removed"                test -e "$FAKE_HOME/.copilot/copilot-instructions.md"
check_false "hooks dir removed"                   test -e "$FAKE_HOME/.copilot/hooks"

# ── file mode kept ────────────────────────────────────────────────────────────

# mode_of <file> — permission bits (GNU stat, else BSD stat).
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo ""
echo "file mode — 600 settings.json stays 600"
seed '{"model":"opus"}'
chmod 600 "$S"
run_install claude
check_true  "claude settings.json 600 after install"    test "$(mode_of "$S")" = 600
run_uninstall claude
check_true  "claude settings.json 600 after uninstall"  test "$(mode_of "$S")" = 600
mkdir -p "$FAKE_HOME/.gemini"
printf '%s\n' '{"general":{"vimMode":true},"hooks":{"BeforeTool":[{"matcher":"x","hooks":[{"type":"command","command":"mine.sh"}]}]}}' > "$G"
chmod 600 "$G"
run_install gemini
check_true  "gemini settings.json 600 after install"    test "$(mode_of "$G")" = 600
run_uninstall gemini
check_true  "gemini settings.json kept on uninstall"    test -f "$G"
check_true  "gemini settings.json 600 after uninstall"  test "$(mode_of "$G")" = 600

# ── full round trip ───────────────────────────────────────────────────────────

echo ""
echo "round trip — claude, all, uninstall all leaves HOME as it was"
seed '{"model":"opus","permissions":{"allow":["WebSearch"]}}'
printf 'MY OWN RULES\n' > "$FAKE_HOME/.claude/CLAUDE.md"
mkdir -p "$FAKE_HOME/.gemini"
printf '%s\n' '{"general":{"vimMode":true}}' > "$FAKE_HOME/.gemini/settings.json"
cp "$FAKE_HOME/.gemini/settings.json" "$TMP/gemini.before"
tree_sig "$FAKE_HOME" > "$TMP/sig.before"
run_install claude
run_install all
run_uninstall all
tree_sig "$FAKE_HOME" > "$TMP/sig.after"
check_true  "same files and contents after uninstall all" diff "$TMP/sig.before" "$TMP/sig.after"
check_true  "settings.json restored"              same_json "$TMP/before.json" "$S"
check_true  "gemini settings.json restored"       same_json "$TMP/gemini.before" "$FAKE_HOME/.gemini/settings.json"
check_false "cursor hooks.json removed"           test -e "$FAKE_PROJECT/.cursor/hooks.json"

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
