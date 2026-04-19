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
#   --skills <list>        — comma-separated skill names to append (e.g. karpathy-guidelines)
#                            Skills tagged [core] are always appended unless --skills none
#
# Default: claude
#
# Re-running is safe. Existing files are backed up before any writes.
# settings.json is merged (not overwritten) — personal settings are preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="${1:-claude}"
SKILLS_ARG=""

# Parse --skills flag (can appear anywhere after the agent arg)
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "--skills" ]]; then
    SKILLS_ARG="${args[$((i+1))]:-}"
  fi
done

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

# ── skills ────────────────────────────────────────────────────────────────────
#
# Skills are appended to the agent's instruction file after install.
# Each SKILL.md has YAML front-matter (stripped before appending).
#
# Selection logic:
#   --skills none              → no skills appended
#   --skills foo,bar           → append only foo and bar
#   (no --skills flag)         → append all skills tagged [core]

# strip_frontmatter <file> — prints SKILL.md body with YAML front-matter removed
strip_frontmatter() {
  awk 'BEGIN{fm=0} /^---/{if(NR==1){fm=1;next}else if(fm){fm=0;next}} !fm{print}' "$1"
}

# skill_has_tag <skill_dir> <tag> — returns 0 if SKILL.md front-matter contains the tag
skill_has_tag() {
  local skill_file="$1/SKILL.md"
  [[ -f "$skill_file" ]] || return 1
  # Extract front-matter block (between first pair of ---) and grep for the tag
  awk '/^---/{if(NR==1){in_fm=1;next}else{exit}} in_fm{print}' "$skill_file" \
    | grep -qE "\b$2\b"
}

# append_skills <instruction_file> — appends selected skills to the instruction file
append_skills() {
  local dest_file="$1"
  [[ -d "$SCRIPT_DIR/skills" ]] || return 0
  [[ "$SKILLS_ARG" == "none" ]] && return 0

  local appended=0
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [[ -f "$skill_dir/SKILL.md" ]] || continue
    local name
    name=$(basename "$skill_dir")

    # Determine if this skill should be included
    local include=0
    if [[ -n "$SKILLS_ARG" ]]; then
      # Explicit list: check if name is in the comma-separated list
      IFS=',' read -ra requested <<< "$SKILLS_ARG"
      for req in "${requested[@]}"; do
        [[ "$req" == "$name" ]] && include=1 && break
      done
    else
      # Default: include core-tagged skills only
      skill_has_tag "$skill_dir" "core" && include=1
    fi

    if [[ "$include" == 1 ]]; then
      printf '\n\n---\n\n' >> "$dest_file"
      strip_frontmatter "$skill_dir/SKILL.md" >> "$dest_file"
      ok "Skill '$name' appended → $(basename "$dest_file")"
      appended=$((appended + 1))
    fi
  done

  [[ "$appended" -eq 0 ]] && log "No skills appended" || true
}

install_claude() {
  local dest="$HOME/.claude"
  mkdir -p "$dest"

  echo "Installing Claude Code guardrails → $dest"

  install_hooks "$dest/hooks"

  backup_if_exists "$dest/CLAUDE.md"
  cp "$SCRIPT_DIR/agents/claude/CLAUDE.md" "$dest/CLAUDE.md"
  append_skills "$dest/CLAUDE.md"
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

  backup_if_exists "$dest/KIRO.md"
  cp "$SCRIPT_DIR/agents/kiro/KIRO.md" "$dest/KIRO.md"
  append_skills "$dest/KIRO.md"
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
  append_skills "$dest/AGENTS.md"
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
