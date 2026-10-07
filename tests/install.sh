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
check_true  "windsurf installed"                  test -f "$FAKE_HOME/.codeium/windsurf/hooks.json"
check_true  "antigravity installed"               test -f "$FAKE_HOME/.gemini/config/hooks.json"
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

echo ""
echo "backup — same-second backup does not overwrite an existing one"
seed '{"model":"opus"}'
BAK="$S.bak.$(date +%Y%m%d%H%M%S)"
printf 'MARKER\n' > "$BAK"
run_install claude
check_true  "existing backup unchanged"           test "$(cat "$BAK")" = MARKER
check_true  "new backup written alongside" \
  test "$(command find "$FAKE_HOME/.claude" -maxdepth 1 -name 'settings.json.bak.*' | wc -l)" -ge 2

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

# ── Windsurf hooks.json + global_rules.md ─────────────────────────────────────

echo ""
echo "windsurf — merge into user hooks.json"
fresh
W="$FAKE_HOME/.codeium/windsurf/hooks.json"
WR="$FAKE_HOME/.codeium/windsurf/memories/global_rules.md"
mkdir -p "$FAKE_HOME/.codeium/windsurf"
printf '%s\n' '{"hooks":{"pre_run_command":[{"command":"python3 /me/check.py","show_output":true}],"pre_user_prompt":[{"command":"mine.sh"}]}}' > "$W"
cp "$W" "$TMP/windsurf.before"
check_true  "install windsurf succeeds"           run_install windsurf
check_true  "hooks.json is valid JSON"            jq empty "$W"
jq_true     "user hooks kept"                     '(.hooks.pre_run_command[0] == {"command":"python3 /me/check.py","show_output":true}) and .hooks.pre_user_prompt == [{"command":"mine.sh"}]' "$W"
jq_true     "our run_command hooks added"         '[.hooks.pre_run_command[].command] | any(test("/\\.codeium/windsurf/hooks/block-env\\.sh$"))' "$W"
jq_true     "block-env-read on read/write/mcp"    '[.hooks.pre_read_code, .hooks.pre_write_code, .hooks.pre_mcp_tool_use | .[].command] | all(test("block-env-read\\.sh$"))' "$W"
jq_true     "no version key added"                'has("version") | not' "$W"
check_true  "hook scripts installed"              test -x "$FAKE_HOME/.codeium/windsurf/hooks/block-env-read.sh"
check_true  "global_rules.md installed"           grep -qF '<!-- agentguard:created -->' "$WR"
check_true  "global_rules.md within 6000 chars"   test "$(wc -c < "$WR")" -le 6000
check_false "karpathy skipped (over the limit)"   grep -qF '<!-- agentguard:skill:karpathy-guidelines -->' "$WR"
check_true  "windsurf tracked" \
  grep -qE '^AGENTGUARD_INSTALLED_AGENTS=.*windsurf' "$FAKE_HOME/.agentguard/config"
cp "$W" "$TMP/windsurf.1"
run_install windsurf
check_true  "hooks.json unchanged by second install" same_json "$TMP/windsurf.1" "$W"
jq_true     "no duplicate commands per event"     '[.hooks[] | map(.command) | length == (unique | length)] | all' "$W"
check_true  "uninstall windsurf succeeds"         run_uninstall windsurf
check_true  "uninstall restores hooks.json"       same_json "$TMP/windsurf.before" "$W"
check_false "global_rules.md removed"             test -e "$WR"
check_false "hooks dir removed"                   test -e "$FAKE_HOME/.codeium/windsurf/hooks"

echo ""
echo "windsurf — no hooks.json: created, then removed on uninstall"
fresh
run_install windsurf
jq_true     "hooks.json created"                  '.hooks.pre_run_command | length == 5' "$W"
run_uninstall windsurf
check_false "hooks.json removed"                  test -e "$W"

echo ""
echo "windsurf — user global_rules.md kept, skills fit the limit or are skipped"
fresh
mkdir -p "$(dirname "$WR")"
printf 'MY RULES\n' > "$WR"
run_install windsurf --skills karpathy-guidelines
check_true  "user rules kept"                     grep -qx 'MY RULES' "$WR"
check_true  "small skill appended"                grep -qF '<!-- agentguard:skill:karpathy-guidelines -->' "$WR"
run_install windsurf --skills go
check_false "skill over the limit skipped"        grep -qF '<!-- agentguard:skill:go -->' "$WR"
run_uninstall windsurf
check_true  "uninstall strips only skills"        test "$(command cat "$WR")" = 'MY RULES'

echo ""
echo "windsurf — invalid hooks.json is refused and left unchanged"
fresh
mkdir -p "$(dirname "$W")"
printf '{"hooks":{},}\n' > "$W"
cp "$W" "$TMP/invalid.json"
check_false "install fails"                       run_install windsurf
check_true  "file byte-identical"                 cmp "$TMP/invalid.json" "$W"
run_uninstall windsurf
check_true  "file still byte-identical"           cmp "$TMP/invalid.json" "$W"

# ── Antigravity hooks.json (named entries) + ~/.gemini/AGENTS.md ──────────────

echo ""
echo "antigravity — merge into user hooks.json"
fresh
A="$FAKE_HOME/.gemini/config/hooks.json"
AR="$FAKE_HOME/.gemini/AGENTS.md"
mkdir -p "$(dirname "$A")"
printf '%s\n' '{"my-linter":{"PostToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"./lint.sh","timeout":10}]}]},"reminder":{"enabled":false,"PreInvocation":[{"type":"command","command":"./r.sh"}]}}' > "$A"
cp "$A" "$TMP/agy.before"
check_true  "install antigravity succeeds"        run_install antigravity
check_true  "hooks.json is valid JSON"            jq empty "$A"
jq_true     "user entries kept"                   '(.["my-linter"].PostToolUse[0].hooks[0].command == "./lint.sh") and (.reminder.enabled == false)' "$A"
jq_true     "our run_command hooks added"         '[.agentguard.PreToolUse[] | select(.matcher == "run_command") | .hooks[].command] | length == 5' "$A"
jq_true     "block-env-read on file tools"        '[.agentguard.PreToolUse[] | select(.matcher | test("view_file")) | .hooks[].command] == ["bash ~/.gemini/config/hooks/block-env-read.sh"]' "$A"
jq_true     "audit-log on PostToolUse"            '.agentguard.PostToolUse[0].hooks[0].command | endswith("audit-log.sh")' "$A"
check_true  "hook scripts installed"              test -x "$FAKE_HOME/.gemini/config/hooks/block-env-read.sh"
check_true  "AGENTS.md installed with marker"     grep -qF '<!-- agentguard:created -->' "$AR"
check_true  "karpathy skill appended"             grep -qF '<!-- agentguard:skill:karpathy-guidelines -->' "$AR"
check_false "GEMINI.md not written"               test -e "$FAKE_HOME/.gemini/GEMINI.md"
check_false "gemini settings.json not written"    test -e "$FAKE_HOME/.gemini/settings.json"
check_true  "antigravity tracked" \
  grep -qE '^AGENTGUARD_INSTALLED_AGENTS=.*antigravity' "$FAKE_HOME/.agentguard/config"
cp "$A" "$TMP/agy.1"
run_install antigravity
check_true  "hooks.json unchanged by second install" same_json "$TMP/agy.1" "$A"
check_true  "one karpathy skill sentinel" \
  test "$(grep -c '<!-- agentguard:skill:karpathy-guidelines -->' "$AR")" -eq 1
# A disabled or edited agentguard entry is reset by a re-run.
jq '.agentguard.enabled = false | .agentguard.PreToolUse = []' "$A" > "$TMP/agy.x" && cp "$TMP/agy.x" "$A"
run_install antigravity
check_true  "re-run restores our entry"           same_json "$TMP/agy.1" "$A"
check_true  "uninstall antigravity succeeds"      run_uninstall antigravity
check_true  "uninstall restores hooks.json"       same_json "$TMP/agy.before" "$A"
check_false "AGENTS.md removed"                   test -e "$AR"
check_false "hooks dir removed"                   test -e "$FAKE_HOME/.gemini/config/hooks"

echo ""
echo "antigravity — no hooks.json: created, then removed on uninstall"
fresh
run_install antigravity
jq_true     "hooks.json created with only ours"   'keys == ["agentguard"]' "$A"
run_uninstall antigravity
check_false "hooks.json removed"                  test -e "$A"

echo ""
echo "antigravity — side by side with gemini"
fresh
run_install gemini
run_install antigravity
check_true  "gemini GEMINI.md present"            test -f "$FAKE_HOME/.gemini/GEMINI.md"
check_true  "gemini hooks present"                test -x "$FAKE_HOME/.gemini/hooks/block-env.sh"
check_true  "antigravity AGENTS.md present"       test -f "$AR"
run_uninstall antigravity
check_true  "gemini GEMINI.md kept"               test -f "$FAKE_HOME/.gemini/GEMINI.md"
check_true  "gemini hooks kept"                   test -x "$FAKE_HOME/.gemini/hooks/block-env.sh"
jq_true     "gemini settings hooks kept"          '.hooks.BeforeTool | length > 0' "$FAKE_HOME/.gemini/settings.json"
run_install antigravity
run_uninstall gemini
check_true  "antigravity hooks kept"              test -x "$FAKE_HOME/.gemini/config/hooks/block-env.sh"
check_true  "antigravity AGENTS.md kept"          test -f "$AR"
check_true  "antigravity check passes"            bash -c "cd '$FAKE_PROJECT' && HOME='$FAKE_HOME' bash '$SCRIPT_DIR/install.sh' check antigravity"

echo ""
echo "antigravity — user AGENTS.md kept, only skills stripped"
fresh
printf 'MY RULES\n' > "$TMP/r" && mkdir -p "$FAKE_HOME/.gemini" && cp "$TMP/r" "$AR"
run_install antigravity
check_true  "user rules kept"                     grep -qx 'MY RULES' "$AR"
check_true  "skill appended"                      grep -qF '<!-- agentguard:skill:karpathy-guidelines -->' "$AR"
run_uninstall antigravity
check_true  "uninstall strips only skills"        test "$(command cat "$AR")" = 'MY RULES'

echo ""
echo "antigravity — invalid hooks.json is refused and left unchanged"
fresh
mkdir -p "$(dirname "$A")"
printf '{"x":{},}\n' > "$A"
cp "$A" "$TMP/invalid.json"
check_false "install fails"                       run_install antigravity
check_true  "file byte-identical"                 cmp "$TMP/invalid.json" "$A"
run_uninstall antigravity
check_true  "file still byte-identical"           cmp "$TMP/invalid.json" "$A"
printf '[]\n' > "$A"
check_false "install fails on a JSON array"       run_install antigravity
check_true  "array left unchanged"                test "$(command cat "$A")" = '[]'

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
W="$FAKE_HOME/.codeium/windsurf/hooks.json"
mkdir -p "$(dirname "$W")"
printf '%s\n' '{"hooks":{"pre_user_prompt":[{"command":"mine.sh"}]}}' > "$W"
chmod 600 "$W"
run_install windsurf
check_true  "windsurf hooks.json 600 after install"     test "$(mode_of "$W")" = 600
run_uninstall windsurf
check_true  "windsurf hooks.json kept on uninstall"     test -f "$W"
check_true  "windsurf hooks.json 600 after uninstall"   test "$(mode_of "$W")" = 600
A="$FAKE_HOME/.gemini/config/hooks.json"
mkdir -p "$(dirname "$A")"
printf '%s\n' '{"mine":{"Stop":[{"type":"command","command":"s.sh"}]}}' > "$A"
chmod 600 "$A"
run_install antigravity
check_true  "antigravity hooks.json 600 after install"   test "$(mode_of "$A")" = 600
run_uninstall antigravity
check_true  "antigravity hooks.json kept on uninstall"   test -f "$A"
check_true  "antigravity hooks.json 600 after uninstall" test "$(mode_of "$A")" = 600

# ── full round trip ───────────────────────────────────────────────────────────

echo ""
echo "round trip — claude, all, uninstall all leaves HOME as it was"
seed '{"model":"opus","permissions":{"allow":["WebSearch"]}}'
printf 'MY OWN RULES\n' > "$FAKE_HOME/.claude/CLAUDE.md"
mkdir -p "$FAKE_HOME/.gemini"
printf '%s\n' '{"general":{"vimMode":true}}' > "$FAKE_HOME/.gemini/settings.json"
cp "$FAKE_HOME/.gemini/settings.json" "$TMP/gemini.before"
mkdir -p "$FAKE_HOME/.codeium/windsurf"
# jq-formatted, as uninstall writes it back, so the byte-level tree_sig matches.
jq . <<< '{"hooks":{"pre_user_prompt":[{"command":"mine.sh"}]}}' > "$FAKE_HOME/.codeium/windsurf/hooks.json"
cp "$FAKE_HOME/.codeium/windsurf/hooks.json" "$TMP/windsurf.before"
mkdir -p "$FAKE_HOME/.gemini/config"
jq . <<< '{"mine":{"Stop":[{"type":"command","command":"s.sh"}]}}' > "$FAKE_HOME/.gemini/config/hooks.json"
tree_sig "$FAKE_HOME" > "$TMP/sig.before"
run_install claude
run_install all
run_uninstall all
tree_sig "$FAKE_HOME" > "$TMP/sig.after"
check_true  "same files and contents after uninstall all" diff "$TMP/sig.before" "$TMP/sig.after"
check_true  "settings.json restored"              same_json "$TMP/before.json" "$S"
check_true  "gemini settings.json restored"       same_json "$TMP/gemini.before" "$FAKE_HOME/.gemini/settings.json"
check_true  "windsurf hooks.json restored"        same_json "$TMP/windsurf.before" "$FAKE_HOME/.codeium/windsurf/hooks.json"
check_false "cursor hooks.json removed"           test -e "$FAKE_PROJECT/.cursor/hooks.json"

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
