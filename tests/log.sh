#!/bin/bash
# tests/log.sh — agentguard log command test suite
#
# Writes audit lines with known timestamps into a fake HOME and checks that
# `agentguard log` reads, filters, prefixes and exits as documented.
#
# Requirements: bash, jq

set -uo pipefail
# Note: -e intentionally omitted — ((pass++)) exits 1 when result is zero under set -e.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0

FAKE_HOME=$(mktemp -d)
FAKE_PROJECT=$(mktemp -d)
EMPTY_HOME=$(mktemp -d)
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME" "$FAKE_PROJECT" "$EMPTY_HOME" "$SHIM_DIR"' EXIT

run_log() { (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" log "$@") 2>/dev/null; }

# check_out <label> <expected stdout> <log args...>
check_out() {
  local label="$1" want="$2" got; shift 2
  got=$(run_log "$@")
  if [[ "$got" == "$want" ]]; then
    printf "  PASS  %s\n" "$label"
    ((pass++))
  else
    printf "  FAIL  %s\n        want: %q\n        got:  %q\n" "$label" "$want" "$got"
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

# Far past / far future timestamps keep --since results independent of the clock.
A='2000-01-01T00:00:00Z tool=Read /repo/README.md'
B='2999-01-01T00:00:01Z BLOCKED hook=block-env.sh tool=Bash cat .env'
C='2999-01-01T00:00:03Z tool=Bash ls'
D='2001-01-01T00:00:00Z BLOCKED hook=block-main-branch.sh tool=Bash git push origin main'
E='2999-01-01T00:00:02Z tool=Edit /repo/x.go'
U='2999-01-01T00:00:04Z tool=Read /home/u/notes.md'

mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.codex" "$FAKE_HOME/.cursor" "$FAKE_PROJECT/.cursor"
printf '%s\n' "$A" > "$FAKE_HOME/.claude/audit.log.1"
printf '%s\n%s\n' "$B" "$C" > "$FAKE_HOME/.claude/audit.log"
printf '%s\n' "$D" > "$FAKE_HOME/.codex/audit.log"
printf '%s\n' "$E" > "$FAKE_PROJECT/.cursor/audit.log"
printf '%s\n' "$U" > "$FAKE_HOME/.cursor/audit.log"
sums_before=$(cksum "$FAKE_HOME/.claude/audit.log" "$FAKE_HOME/.claude/audit.log.1" "$FAKE_HOME/.codex/audit.log")

nl=$'\n'

echo "log — one agent"
check_out "claude: rotated file first, no prefix" "$A$nl$B$nl$C" claude
check_out "claude --blocked"                      "$B"            claude --blocked
check_out "claude --tail 1"                       "$C"            claude --tail 1
check_out "claude --tail 0 shows all"             "$A$nl$B$nl$C" claude --tail 0
check_out "claude --since 2h drops old lines"     "$B$nl$C"      claude --since 2h
check_out "claude --since 30m --blocked"          "$B"            claude --since 30m --blocked
check_out "codex only has its own lines"          "$D"            codex
check_out "cursor reads the project log"          "$E"            cursor
check_out "cursor --user reads ~/.cursor"         "$U"            cursor --user
check_out "cursor-user reads ~/.cursor"           "$U"            cursor-user

echo ""
echo "log — all agents"
check_out "default is all: prefixed, time order" \
  "claude  $A${nl}codex  $D${nl}claude  $B${nl}cursor  $E${nl}claude  $C${nl}cursor-user  $U"
check_out "all --blocked" "codex  $D${nl}claude  $B" all --blocked
check_out "all --tail 2"  "claude  $C${nl}cursor-user  $U" all --tail 2
check_out "flag first still means all" "codex  $D${nl}claude  $B" --blocked

echo ""
echo "log — missing logs and bad input"
check_exit "missing agent log exits 1" 1 run_log kiro
hint=$( (cd "$FAKE_PROJECT" && HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" log kiro) 2>&1 >/dev/null)
if [[ "$hint" == *"no audit log for kiro at $FAKE_HOME/.kiro/audit.log; is it installed?"* ]]; then
  printf "  PASS  %s\n" "missing log prints a hint"; ((pass++))
else
  printf "  FAIL  %s: %s\n" "missing log prints a hint" "$hint"; ((fail++))
fi
check_exit "nothing installed exits 1" 1 \
  bash -c 'cd "$1" && HOME="$2" bash "$3/install.sh" log' _ "$EMPTY_HOME" "$EMPTY_HOME" "$SCRIPT_DIR"
check_exit "logs found exits 0"       0 run_log claude
check_exit "unknown agent exits 1"    1 run_log nope
check_exit "bad --tail exits 1"       1 run_log claude --tail x
check_exit "bad --since exits 1"      1 run_log claude --since 2w
check_exit "--since without value exits 1" 1 run_log claude --since

echo ""
echo "log — BSD date fallback"
# A date that rejects GNU -d and answers BSD -r N, like macOS date.
REAL_DATE=$(command -v date)
cat > "$SHIM_DIR/date" <<EOF
#!/bin/bash
for a in "\$@"; do [[ "\$a" == -d ]] && { echo "date: illegal option -- d" >&2; exit 1; }; done
if [[ "\$1" == -u && "\$2" == -r ]]; then
  # Real BSD date answers -r itself; GNU date needs -d @N.
  "$REAL_DATE" -u -r "\$3" "\$4" 2>/dev/null && exit 0
  exec "$REAL_DATE" -u -d "@\$3" "\$4"
fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$SHIM_DIR/date"
got=$( (cd "$FAKE_PROJECT" && PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/install.sh" log claude --since 2h) 2>/dev/null)
if [[ "$got" == "$B$nl$C" ]]; then
  printf "  PASS  %s\n" "--since works with BSD-style date"; ((pass++))
else
  printf "  FAIL  %s: %q\n" "--since works with BSD-style date" "$got"; ((fail++))
fi

echo ""
echo "log — read only"
sums_after=$(cksum "$FAKE_HOME/.claude/audit.log" "$FAKE_HOME/.claude/audit.log.1" "$FAKE_HOME/.codex/audit.log")
if [[ "$sums_before" == "$sums_after" ]]; then
  printf "  PASS  %s\n" "logs are not modified"; ((pass++))
else
  printf "  FAIL  %s\n" "logs are not modified"; ((fail++))
fi

# ── results ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
