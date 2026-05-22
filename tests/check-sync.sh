#!/bin/bash
# tests/check-sync.sh — assert instruction files are in sync
#
# CLAUDE.md, KIRO.md, and agents/cursor/AGENTS.md must be byte-for-byte identical.
# agents/codex/AGENTS.md must match CLAUDE.md modulo its intentional Codex-only header
# (the three-line block on lines 3-5 that documents it as a Codex file).
#
# Exit 0 = in sync. Exit 1 = drift detected (prints diff).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE="$SCRIPT_DIR/agents/claude/CLAUDE.md"
KIRO="$SCRIPT_DIR/agents/kiro/KIRO.md"
AGENTS="$SCRIPT_DIR/agents/codex/AGENTS.md"
CURSOR_AGENTS="$SCRIPT_DIR/agents/cursor/AGENTS.md"

fail=0

# ── Claude vs Kiro ────────────────────────────────────────────────────────────

if ! diff -u "$CLAUDE" "$KIRO" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/kiro/KIRO.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$KIRO" || true
  fail=1
else
  echo "PASS  CLAUDE.md == KIRO.md"
fi

# ── Claude vs Codex (strip known header before comparing) ─────────────────────
#
# AGENTS.md has an intentional header after the title line:
#
#   > Codex instruction file. Keep in sync with agents/claude/CLAUDE.md.
#   > Enforcement is instruction-only — Codex has no shell hooks.
#   (blank line)
#
# Strip those three lines then diff against CLAUDE.md.

AGENTS_STRIPPED=$(mktemp)
trap 'rm -f "$AGENTS_STRIPPED"' EXIT

awk '
  NR == 3 && /^> Codex instruction file/ { skip=1; next }
  NR == 4 && /^> Enforcement is instruction-only/ { next }
  NR == 5 && /^$/ && skip { skip=0; next }
  { print }
' "$AGENTS" > "$AGENTS_STRIPPED"

if ! diff -u "$CLAUDE" "$AGENTS_STRIPPED" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/codex/AGENTS.md have drifted"
  echo "      (AGENTS.md shown with Codex-only header stripped):"
  echo ""
  diff -u "$CLAUDE" "$AGENTS_STRIPPED" || true
  fail=1
else
  echo "PASS  CLAUDE.md == AGENTS.md (modulo Codex header)"
fi

# ── Claude vs Cursor (byte-for-byte identical) ───────────────────────────────

if ! diff -u "$CLAUDE" "$CURSOR_AGENTS" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/cursor/AGENTS.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$CURSOR_AGENTS" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/cursor/AGENTS.md"
fi

# ── result ────────────────────────────────────────────────────────────────────

echo ""
if [[ "$fail" -eq 0 ]]; then
  echo "All instruction files in sync."
  exit 0
else
  echo "Instruction file drift detected. Edit the files to re-sync, then re-run."
  echo "Canonical source: agents/claude/CLAUDE.md — copy to kiro/KIRO.md and cursor/AGENTS.md"
  exit 1
fi
