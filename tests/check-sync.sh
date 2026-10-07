#!/bin/bash
# tests/check-sync.sh — assert instruction files are in sync
#
# CLAUDE.md, KIRO.md, agents/codex/AGENTS.md, agents/cursor/AGENTS.md,
# agents/gemini/GEMINI.md, agents/copilot/copilot-instructions.md,
# agents/windsurf/global_rules.md and agents/antigravity/AGENTS.md must be
# byte-for-byte identical.
#
# Exit 0 = in sync. Exit 1 = drift detected (prints diff).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE="$SCRIPT_DIR/agents/claude/CLAUDE.md"
KIRO="$SCRIPT_DIR/agents/kiro/KIRO.md"
AGENTS="$SCRIPT_DIR/agents/codex/AGENTS.md"
CURSOR_AGENTS="$SCRIPT_DIR/agents/cursor/AGENTS.md"
GEMINI="$SCRIPT_DIR/agents/gemini/GEMINI.md"
COPILOT="$SCRIPT_DIR/agents/copilot/copilot-instructions.md"
WINDSURF="$SCRIPT_DIR/agents/windsurf/global_rules.md"
ANTIGRAVITY="$SCRIPT_DIR/agents/antigravity/AGENTS.md"

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

# ── Claude vs Codex (byte-for-byte identical) ────────────────────────────────

if ! diff -u "$CLAUDE" "$AGENTS" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/codex/AGENTS.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$AGENTS" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/codex/AGENTS.md"
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

# ── Claude vs Gemini (byte-for-byte identical) ───────────────────────────────

if ! diff -u "$CLAUDE" "$GEMINI" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/gemini/GEMINI.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$GEMINI" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/gemini/GEMINI.md"
fi

# ── Claude vs Copilot (byte-for-byte identical) ──────────────────────────────

if ! diff -u "$CLAUDE" "$COPILOT" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/copilot/copilot-instructions.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$COPILOT" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/copilot/copilot-instructions.md"
fi

# ── Claude vs Windsurf (byte-for-byte identical, within the rules limit) ─────

if ! diff -u "$CLAUDE" "$WINDSURF" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/windsurf/global_rules.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$WINDSURF" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/windsurf/global_rules.md"
fi
# Windsurf limits global_rules.md to 6,000 characters; leave room for the
# created marker the installer appends.
if [[ "$(wc -c < "$WINDSURF")" -gt 5900 ]]; then
  echo "FAIL  agents/windsurf/global_rules.md is over 5900 bytes (Windsurf global rules limit: 6000 characters)"
  fail=1
else
  echo "PASS  agents/windsurf/global_rules.md fits the Windsurf global rules limit"
fi

# ── Claude vs Antigravity (byte-for-byte identical) ──────────────────────────

if ! diff -u "$CLAUDE" "$ANTIGRAVITY" >/dev/null 2>&1; then
  echo "FAIL  agents/claude/CLAUDE.md and agents/antigravity/AGENTS.md have drifted:"
  echo ""
  diff -u "$CLAUDE" "$ANTIGRAVITY" || true
  fail=1
else
  echo "PASS  CLAUDE.md == agents/antigravity/AGENTS.md"
fi

# ── result ────────────────────────────────────────────────────────────────────

echo ""
if [[ "$fail" -eq 0 ]]; then
  echo "All instruction files in sync."
  exit 0
else
  echo "Instruction file drift detected. Edit the files to re-sync, then re-run."
  echo "Canonical source: agents/claude/CLAUDE.md — copy to kiro/KIRO.md, codex/AGENTS.md, cursor/AGENTS.md, gemini/GEMINI.md, copilot/copilot-instructions.md, windsurf/global_rules.md and antigravity/AGENTS.md"
  exit 1
fi
