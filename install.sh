#!/bin/bash
# install.sh
#
# Installs (or uninstalls) AI agent guardrails to their tool-specific config locations.
#
# Usage:
#   ./install.sh [claude|codex|kiro|all]           — install (default: claude)
#   ./install.sh uninstall [claude|codex|kiro|all] — remove guardrails
#
#   --skills <list>        — comma-separated skill names to append (e.g. karpathy-guidelines)
#                            Skills tagged [core] are always appended unless --skills none
#   --dry-run              — show what would be changed without writing anything
#
# Re-running install is safe. Existing files are backed up before any writes.
# settings.json is merged (not overwritten) — personal settings are preserved.
# Uninstall backs up before every destructive write and strips only agentguard entries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="${1:-claude}"
SKILLS_ARG=""
DRY_RUN=0
UNINSTALL=0

# Detect uninstall subcommand: ./install.sh uninstall [agent]
if [[ "$AGENT" == "uninstall" ]]; then
  UNINSTALL=1
  AGENT="${2:-claude}"
  # Shift so flag parsing below sees the right positions
  shift || true
fi

# Parse flags (can appear anywhere after the agent arg)
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == "--skills" ]]; then
    SKILLS_ARG="${args[$((i+1))]:-}"
  fi
  if [[ "${args[$i]}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
done

# If the first positional arg is a flag (e.g. ./install.sh --dry-run), default agent to claude
if [[ "$AGENT" == --* ]]; then
  AGENT="claude"
fi

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { printf '  %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
dry()  { printf '  [dry-run] %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."
}

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would back up $(basename "$file") → $(basename "$file").bak.<timestamp>"
    else
      local ts
      ts=$(date +%Y%m%d%H%M%S)
      cp "$file" "${file}.bak.${ts}"
      log "Backed up $(basename "$file") → $(basename "$file").bak.${ts}"
    fi
  fi
}

# ── hook installation ─────────────────────────────────────────────────────────

install_hooks() {
  local dest="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would install hooks → $dest"
    for f in "$SCRIPT_DIR/hooks/"*.sh; do
      dry "  copy $(basename "$f") → $dest/$(basename "$f")"
    done
    return
  fi
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

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -f "$existing" ]]; then
      dry "Would merge settings.json → $output (existing file found, merging)"
    else
      dry "Would write settings.json → $output (no existing file, writing fresh)"
    fi
    return
  fi

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
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would append skill '$name' → $(basename "$dest_file")"
        appended=$((appended + 1))
      else
        printf '\n\n---\n\n' >> "$dest_file"
        strip_frontmatter "$skill_dir/SKILL.md" >> "$dest_file"
        ok "Skill '$name' appended → $(basename "$dest_file")"
        appended=$((appended + 1))
      fi
    fi
  done

  [[ "$appended" -eq 0 ]] && log "No skills appended" || true
}

install_claude() {
  local dest="$HOME/.claude"

  echo "Installing Claude Code guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  install_hooks "$dest/hooks"

  backup_if_exists "$dest/CLAUDE.md"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy CLAUDE.md → $dest/CLAUDE.md"
  else
    mkdir -p "$dest"
    cp "$SCRIPT_DIR/agents/claude/CLAUDE.md" "$dest/CLAUDE.md"
    ok "CLAUDE.md installed"
  fi
  append_skills "$dest/CLAUDE.md"

  backup_if_exists "$dest/settings.json"
  merge_settings "$dest/settings.json" \
                 "$SCRIPT_DIR/agents/claude/settings.json" \
                 "$dest/settings.json"
}

install_kiro() {
  local dest="$HOME/.kiro"

  echo "Installing Kiro guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  install_hooks "$dest/hooks"

  backup_if_exists "$dest/KIRO.md"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy KIRO.md → $dest/KIRO.md"
  else
    mkdir -p "$dest"
    cp "$SCRIPT_DIR/agents/kiro/KIRO.md" "$dest/KIRO.md"
    ok "KIRO.md installed"
  fi
  append_skills "$dest/KIRO.md"

  local agent_dest="$dest/agents"
  backup_if_exists "$agent_dest/agentguard.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy agent.json → $agent_dest/agentguard.json"
  else
    mkdir -p "$agent_dest"
    cp "$SCRIPT_DIR/agents/kiro/agent.json" "$agent_dest/agentguard.json"
    ok "agentguard agent config installed → $agent_dest/agentguard.json"
  fi
}

install_codex() {
  # Codex reads AGENTS.md from the working directory or home directory.
  # Shell hooks are not supported — AGENTS.md is the only enforcement layer.
  local dest="$HOME"

  echo "Installing Codex guardrails → $dest/AGENTS.md"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  backup_if_exists "$dest/AGENTS.md"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy AGENTS.md → $dest/AGENTS.md"
  else
    cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$dest/AGENTS.md"
    ok "AGENTS.md installed"
  fi
  append_skills "$dest/AGENTS.md"
  log "Note: Codex does not support shell hooks — instruction file only."
}

# ── uninstallers ──────────────────────────────────────────────────────────────
#
# Uninstall removes only the files agentguard owns:
#   - Hook scripts in the agent's hooks/ directory (matched by name)
#   - The instruction file (CLAUDE.md / KIRO.md / AGENTS.md)
#   - The Kiro agent config (agentguard.json)
#   - For Claude: our entries are stripped from settings.json (not deleted wholesale)
#
# Every destructive write is preceded by a backup, same as install.
# --dry-run is fully supported.

# Our hook filenames — used to identify which files to remove
AGENTGUARD_HOOKS=(
  audit-log.sh
  block-destructive-ops.sh
  block-env-read.sh
  block-env.sh
  block-main-branch.sh
  block-system-installs.sh
)

# remove_hooks <hooks_dir> — removes agentguard hook files from the given directory
remove_hooks() {
  local dir="$1"
  local removed=0
  for hook in "${AGENTGUARD_HOOKS[@]}"; do
    local f="$dir/$hook"
    if [[ -f "$f" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would remove $f"
      else
        rm "$f"
        log "Removed $f"
      fi
      removed=$((removed + 1))
    fi
  done
  if [[ "$removed" -eq 0 ]]; then
    log "No hooks found in $dir (already removed?)"
  elif [[ "$DRY_RUN" -eq 0 ]]; then
    ok "Hooks removed from $dir"
  fi
}

# remove_file <path> — backs up and removes a file if it exists
remove_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    backup_if_exists "$f"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would remove $f"
    else
      rm "$f"
      ok "Removed $f"
    fi
  else
    log "$(basename "$f") not found (already removed?)"
  fi
}

# unmerge_settings <settings_path> <guardrails_path>
#
# Strips agentguard entries from an existing settings.json:
#   - Removes our hook commands from PreToolUse / PostToolUse.
#     Matcher blocks that become empty after removal are dropped entirely.
#   - Removes our permission entries from allow / ask / deny arrays.
#   - Removes the security-critical scalars we set
#     (includeCoAuthoredBy, gitAttribution, disableGitWorkflow).
#
# All other user keys are preserved untouched.
unmerge_settings() {
  local settings="$1"
  local guardrails="$2"

  require jq

  if [[ ! -f "$settings" ]]; then
    log "settings.json not found — nothing to unmerge"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would unmerge agentguard entries from $settings"
    return
  fi

  local guard_json
  guard_json=$(cat "$guardrails")

  backup_if_exists "$settings"

  jq -n \
    --argjson current "$(cat "$settings")" \
    --argjson guard   "$guard_json" \
    '
    # Collect the set of hook command strings we own (from the guardrails config).
    # Both PreToolUse and PostToolUse use the same shape.
    # Note: commands are matched by exact string (e.g. "bash ~/.claude/hooks/block-env.sh").
    # If the user installed with a non-default HOME the paths in the installed file will
    # differ from the paths in the source guardrails json, so those entries will not be
    # matched and will be left in place. This is an accepted gap — the user can remove
    # them manually, or re-install from the correct HOME before uninstalling.
    def guard_commands:
      [ ($guard.hooks.PreToolUse  // [] | .[].hooks // [] | .[].command),
        ($guard.hooks.PostToolUse // [] | .[].hooks // [] | .[].command) ]
      | flatten | unique;

    # Remove our hook commands from a hooks array; drop the whole matcher block
    # if no hooks remain.
    def strip_hooks(harr):
      harr
      | map(
          .hooks = (.hooks // [] | map(select(.command as $c | guard_commands | index($c) == null)))
        )
      | map(select(.hooks | length > 0));

    # Collect the permission entries we own from the guardrails config.
    def guard_perms(key): $guard.permissions[key] // [];

    # Remove our entries from a permissions array.
    def strip_perms(arr; key):
      arr | map(select(. as $e | guard_perms(key) | index($e) == null));

    # Strip our entries, then remove the permissions object entirely if all three
    # arrays are now empty and no other meaningful keys remain — avoids polluting
    # a settings.json that had no permissions key before install.
    # defaultMode is included in the "ours" set: it was written by merge_settings
    # and should not be left behind as an orphan when nothing else remains.
    def clean_permissions:
      .permissions.allow = strip_perms((.permissions.allow // []); "allow")
      | .permissions.ask   = strip_perms((.permissions.ask   // []); "ask")
      | .permissions.deny  = strip_perms((.permissions.deny  // []); "deny")
      | if (.permissions.allow == [] and .permissions.ask == [] and .permissions.deny == [])
          and (.permissions | keys | map(select(
                . != "allow" and . != "ask" and . != "deny" and . != "defaultMode"
              )) | length == 0)
        then del(.permissions)
        else .
        end;

    $current
    | clean_permissions
    | .hooks.PreToolUse  = strip_hooks(.hooks.PreToolUse  // [])
    | .hooks.PostToolUse = strip_hooks(.hooks.PostToolUse // [])
    | del(.includeCoAuthoredBy)
    | del(.gitAttribution)
    | del(.disableGitWorkflow)
    ' > "${settings}.tmp" && mv "${settings}.tmp" "$settings"

  ok "settings.json unmerged → $settings"
}

uninstall_claude() {
  local dest="$HOME/.claude"

  echo "Uninstalling Claude Code guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_file  "$dest/CLAUDE.md"
  unmerge_settings "$dest/settings.json" "$SCRIPT_DIR/agents/claude/settings.json"
}

uninstall_kiro() {
  local dest="$HOME/.kiro"

  echo "Uninstalling Kiro guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_file  "$dest/KIRO.md"
  remove_file  "$dest/agents/agentguard.json"
}

uninstall_codex() {
  local dest="$HOME"

  echo "Uninstalling Codex guardrails from $dest/AGENTS.md"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_file "$dest/AGENTS.md"
  log "Note: no hooks to remove — Codex is instruction-file only."
}

# ── entry point ───────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" -eq 1 ]]; then
  case "$AGENT" in
    claude) uninstall_claude ;;
    codex)  uninstall_codex  ;;
    kiro)   uninstall_kiro   ;;
    all)    uninstall_claude; echo; uninstall_codex; echo; uninstall_kiro ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | all" ;;
  esac
  echo ""
  echo "Done."
  [[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no files were changed)"
  exit 0
fi

case "$AGENT" in
  claude) install_claude ;;
  codex)  install_codex  ;;
  kiro)   install_kiro   ;;
  all)    install_claude; echo; install_codex; echo; install_kiro ;;
  *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | all" ;;
esac

echo ""
echo "Done."
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: no files were written)"
[[ "$AGENT" == "claude" || "$AGENT" == "all" ]] && [[ "$DRY_RUN" -eq 0 ]] && \
  echo "Run 'claude --print-config' to verify Claude settings."
[[ "$AGENT" == "kiro" || "$AGENT" == "all" ]] && [[ "$DRY_RUN" -eq 0 ]] && \
  echo "Switch to the 'agentguard' agent in Kiro to activate guardrails."
