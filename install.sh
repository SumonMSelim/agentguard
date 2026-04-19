#!/bin/bash
# install.sh
#
# Installs AI agent guardrails to their tool-specific config locations.
#
# Usage:
#   ./install.sh claude    — install for Claude Code
#   ./install.sh codex     — install for Codex
#   ./install.sh kiro      — install for Kiro
#   ./install.sh all       — install for all supported agents
#
# Default: claude
#
# Re-running is safe. Existing files are backed up before any writes.
# settings.json is merged (not overwritten) — personal settings are preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="${1:-claude}"

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { printf '  %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."
}

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    cp "$file" "${file}.bak.${ts}"
    log "Backed up $(basename "$file") → $(basename "$file").bak.${ts}"
  fi
}

# ── hook installation ─────────────────────────────────────────────────────────

install_hooks() {
  local dest="$1"
  mkdir -p "$dest"
  # Copy only shared hooks (exclude agent-specific prefixed files if any are added later)
  cp "$SCRIPT_DIR/hooks/"*.sh "$dest/"
  chmod +x "$dest/"*.sh
  ok "Hooks installed → $dest"
}

# ── settings.json merge ───────────────────────────────────────────────────────
#
# Merge strategy when an existing settings.json is found:
#
#   permissions arrays (allow / ask / deny)
#     Union of existing + guardrails arrays, deduplicated.
#     Guardrail rules are additive; your existing rules are preserved.
#
#   hooks.PreToolUse / hooks.PostToolUse
#     Merged by matcher key. For each matcher in the guardrails config, if you
#     already have a block for that matcher, our hooks are appended to it
#     (deduplicated by command string). New matchers are added as whole blocks.
#
#   permissions.defaultMode
#     User value wins (it's a UX preference, not security-critical). Falls back
#     to "acceptEdits" if neither side sets it.
#
#   Security-critical scalars
#     (includeCoAuthoredBy, gitAttribution, disableGitWorkflow)
#     Guardrails value always wins.
#
#   All other user keys (env, model, apiKey, Bedrock config, etc.)
#     Preserved exactly as you have them.

merge_settings() {
  local existing="$1"    # existing settings.json path (may not exist)
  local guardrails="$2"  # guardrails source file
  local output="$3"      # destination (may be same path as existing)

  require jq

  local user_json='{}'
  [[ -f "$existing" ]] && user_json=$(cat "$existing")
  local guard_json
  guard_json=$(cat "$guardrails")

  jq -n \
    --argjson user  "$user_json" \
    --argjson guard "$guard_json" \
    '
    def union_arr(a; b): ((a // []) + (b // [])) | unique;

    # Merge PreToolUse hook arrays.
    # For each guardrail matcher block:
    #   - if the user has the same matcher, append our hooks (dedup by command)
    #   - if not, add the entire block
    def merge_hooks(uarr; garr):
      (garr | map({(.matcher): .hooks}) | add // {}) as $gi |
      (uarr | map(
        .matcher as $m |
        if ($gi | has($m)) then
          .hooks = ((.hooks // []) + $gi[$m] | unique_by(.command))
        else . end
      )) +
      (garr | map(select(
        .matcher as $gm |
        (uarr | map(.matcher) | index($gm)) == null
      )));

    # Start from the user object so all personal keys are preserved,
    # then apply targeted guardrail overrides.
    $user
    | .permissions.allow       = union_arr($user.permissions.allow;       $guard.permissions.allow)
    | .permissions.ask         = union_arr($user.permissions.ask;         $guard.permissions.ask)
    | .permissions.deny        = union_arr($user.permissions.deny;        $guard.permissions.deny)
    | .permissions.defaultMode = ($user.permissions.defaultMode // $guard.permissions.defaultMode // "acceptEdits")
    | .hooks.PreToolUse        = merge_hooks(
                                   ($user.hooks.PreToolUse  // []);
                                   ($guard.hooks.PreToolUse // [])
                                 )
    | .hooks.PostToolUse       = merge_hooks(
                                   ($user.hooks.PostToolUse  // []);
                                   ($guard.hooks.PostToolUse // [])
                                 )
    | .includeCoAuthoredBy     = $guard.includeCoAuthoredBy
    | .gitAttribution          = $guard.gitAttribution
    | .disableGitWorkflow      = $guard.disableGitWorkflow
    ' > "$output"

  ok "settings.json merged → $output"
}

# ── agent installers ──────────────────────────────────────────────────────────

install_skills() {
  local dest="$1"
  if [[ -d "$SCRIPT_DIR/skills" ]]; then
    if [[ -d "$dest/skills" ]]; then
      local ts
      ts=$(date +%Y%m%d%H%M%S)
      cp -r "$dest/skills" "${dest}/skills.bak.${ts}"
      log "Backed up skills → skills.bak.${ts}"
    fi
    mkdir -p "$dest/skills"
    cp -r "$SCRIPT_DIR/skills/"* "$dest/skills/"
    ok "Skills installed → $dest/skills"
  fi
}

install_claude() {
  local dest="$HOME/.claude"
  mkdir -p "$dest"

  echo "Installing Claude Code guardrails → $dest"

  install_hooks "$dest/hooks"
  install_skills "$dest"

  backup_if_exists "$dest/CLAUDE.md"
  cp "$SCRIPT_DIR/agents/claude/CLAUDE.md" "$dest/CLAUDE.md"
  ok "CLAUDE.md installed"

  backup_if_exists "$dest/settings.json"
  merge_settings "$dest/settings.json" \
                 "$SCRIPT_DIR/agents/claude/settings.json" \
                 "$dest/settings.json"
}

install_kiro() {
  local dest="$HOME/.kiro"
  mkdir -p "$dest"

  echo "Installing Kiro guardrails → $dest"

  install_hooks "$dest/hooks"
  install_skills "$dest"

  backup_if_exists "$dest/KIRO.md"
  cp "$SCRIPT_DIR/agents/kiro/KIRO.md" "$dest/KIRO.md"
  ok "KIRO.md installed"

  local agent_dest="$dest/agents"
  mkdir -p "$agent_dest"
  backup_if_exists "$agent_dest/agentguard.json"
  cp "$SCRIPT_DIR/agents/kiro/agent.json" "$agent_dest/agentguard.json"
  ok "agentguard agent config installed → $agent_dest/agentguard.json"
}

install_codex() {
  # Codex reads AGENTS.md from the working directory or home directory.
  # Shell hooks are not supported — AGENTS.md is the only enforcement layer.
  local dest="$HOME"

  echo "Installing Codex guardrails → $dest/AGENTS.md"

  backup_if_exists "$dest/AGENTS.md"
  cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$dest/AGENTS.md"
  ok "AGENTS.md installed"
  log "Note: Codex does not support shell hooks — instruction file only."
}

# ── entry point ───────────────────────────────────────────────────────────────

case "$AGENT" in
  claude) install_claude ;;
  codex)  install_codex  ;;
  kiro)   install_kiro   ;;
  all)    install_claude; echo; install_codex; echo; install_kiro ;;
  *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | all" ;;
esac

echo ""
echo "Done."
[[ "$AGENT" == "claude" || "$AGENT" == "all" ]] && \
  echo "Run 'claude --print-config' to verify Claude settings."
[[ "$AGENT" == "kiro" || "$AGENT" == "all" ]] && \
  echo "Switch to the 'agentguard' agent in Kiro to activate guardrails."
