#!/bin/bash
# install.sh
#
# Installs (or uninstalls) AI agent guardrails to their tool-specific config locations.
# Also installs an `agentguard` CLI wrapper to ~/.local/bin/ so you can run
# `agentguard <cmd>` from any directory after the initial install.
#
# Usage:
#   ./install.sh [claude|codex|kiro|cursor|all]           — install (default: claude)
#   ./install.sh uninstall [claude|codex|kiro|cursor|all] — remove guardrails
#   ./install.sh check [claude|codex|kiro|cursor|all]     — report installation status (no writes)
#   ./install.sh upgrade                                   — git pull + reinstall all tracked agents
#
#   --skills <list>        — comma-separated skill names to append (e.g. karpathy-guidelines)
#                            Skills tagged [core] are always appended unless --skills none
#   --dry-run              — show what would be changed without writing anything
#   --project              — append skills to the project-level instruction file in CWD
#                            Claude: .claude/CLAUDE.md  Codex: AGENTS.md  Kiro: not supported
#
# Re-running install is safe. Existing files are backed up before any writes.
# settings.json is merged (not overwritten) — personal settings are preserved.
# Uninstall backs up before every destructive write and strips only agentguard entries.
# Check exits 0 if everything is in order, 1 if any issues are found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTGUARD_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
AGENT="${1:-claude}"
SKILLS_ARG=""
DRY_RUN=0
UNINSTALL=0
CHECK=0
PROJECT=0
UPGRADE=0

# Detect subcommands: ./install.sh uninstall|check|upgrade [agent]
if [[ "$AGENT" == "version" || "$AGENT" == "--version" || "$AGENT" == "-v" ]]; then
  echo "agentguard ${AGENTGUARD_VERSION}"
  exit 0
elif [[ "$AGENT" == "uninstall" ]]; then
  UNINSTALL=1
  AGENT="${2:-claude}"
  shift || true
elif [[ "$AGENT" == "check" ]]; then
  CHECK=1
  AGENT="${2:-claude}"
  shift || true
elif [[ "$AGENT" == "upgrade" ]]; then
  UPGRADE=1
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
  if [[ "${args[$i]}" == "--project" ]]; then
    PROJECT=1
  fi
done

# If the first positional arg is a flag (e.g. ./install.sh --dry-run), default agent to claude
if [[ "$AGENT" == --* ]]; then
  AGENT="claude"
fi

# ── helpers ───────────────────────────────────────────────────────────────────

# ANSI color codes — stdout colors disabled when not a terminal; stderr colors
# checked separately so fail() stays colored even when stdout is redirected.
if [[ -t 1 ]]; then
  _C_GREEN='\033[0;32m'; _C_YELLOW='\033[0;33m'; _C_RED='\033[0;31m'
  _C_CYAN='\033[0;36m';  _C_GRAY='\033[0;90m'; _C_BOLD='\033[1m'; _C_RESET='\033[0m'
else
  _C_GREEN=''; _C_YELLOW=''; _C_RED=''; _C_CYAN=''; _C_GRAY=''; _C_BOLD=''; _C_RESET=''
fi
if [[ -t 2 ]]; then
  _C_ERR_RED='\033[0;31m'; _C_ERR_BOLD='\033[1m'; _C_ERR_RESET='\033[0m'
else
  _C_ERR_RED=''; _C_ERR_BOLD=''; _C_ERR_RESET=''
fi

log()  { printf "${_C_GRAY}  [INFO]${_C_RESET}    %s\n" "$*"; }
ok()   { printf "${_C_GREEN}  [SUCCESS]${_C_RESET} %s\n" "$*"; }
fail() { printf "${_C_ERR_BOLD}${_C_ERR_RED}\n  [ERROR]   %s\n\n${_C_ERR_RESET}" "$*" >&2; exit 1; }
dry()  { printf "${_C_CYAN}  [DRY-RUN]${_C_RESET} %s\n" "$*"; }
warn() { printf "${_C_YELLOW}  [WARNING]${_C_RESET}  %s\n" "$*"; }

section() { printf "\n${_C_BOLD}%s${_C_RESET}\n" "$*"; }

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

# ── interactive config ────────────────────────────────────────────────────────
#
# Prompts the user for git branches to protect from direct commit/push and
# writes them to ~/.agentguard/config. hooks/block-main-branch.sh parses
# that file at runtime (never sources it) when AGENTGUARD_PROTECTED_BRANCHES
# is not already set. Input is validated against a strict charset before
# being persisted so a malicious entry cannot reach the hook.
#
# Re-running install re-prompts; the previously saved value becomes the new
# default so the user can keep it with one Enter.
#
# Non-TTY (CI, piped stdin): silently uses the default. Dry-run: no write.

AGENTGUARD_CONFIG_DIR="$HOME/.agentguard"
AGENTGUARD_CONFIG_FILE="$AGENTGUARD_CONFIG_DIR/config"
DEFAULT_PROTECTED_BRANCHES="main,master"

prompt_protected_branches() {
  local default="$DEFAULT_PROTECTED_BRANCHES"

  # If a previous install wrote a value, use it as the new default.
  if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
    local prev
    prev=$(grep -E '^AGENTGUARD_PROTECTED_BRANCHES=' "$AGENTGUARD_CONFIG_FILE" \
           | tail -n1 \
           | sed -E 's/^AGENTGUARD_PROTECTED_BRANCHES=//; s/^"//; s/"$//') || true
    [[ -n "$prev" ]] && default="$prev"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would prompt for protected branches; default: $default"
    dry "Would write → $AGENTGUARD_CONFIG_FILE"
    return
  fi

  local input=""
  if [[ -t 0 ]]; then
    echo ""
    printf "\n${_C_BOLD}Protected branches${_C_RESET}\n"
    echo "  Which branches should be protected from direct commit/push?"
    echo "  Enter a comma-separated list, or press Enter to keep the default."
    printf "  Branches [%s]: " "$default"
    read -r input || true
  else
    log "No TTY — using default protected branches: $default"
  fi

  local value="${input:-$default}"
  value=$(echo "$value" | tr -d '[:space:]')

  # Validate before writing — the config file is sourced/parsed at hook
  # runtime, so anything outside the documented charset must be rejected
  # to prevent shell injection via the persisted value.
  if [[ ! "$value" =~ ^[a-zA-Z0-9_,/.-]+$ ]]; then
    log "Invalid characters in '$value' — falling back to default '$DEFAULT_PROTECTED_BRANCHES'"
    value="$DEFAULT_PROTECTED_BRANCHES"
  fi

  mkdir -p "$AGENTGUARD_CONFIG_DIR"
  cat > "$AGENTGUARD_CONFIG_FILE" <<EOF
# agentguard config — written by install.sh
# Parsed (not sourced) by hooks/block-main-branch.sh when
# AGENTGUARD_PROTECTED_BRANCHES is not already set in the environment.
AGENTGUARD_PROTECTED_BRANCHES="$value"
EOF
  chmod 644 "$AGENTGUARD_CONFIG_FILE"
  ok "Protected branches saved → $AGENTGUARD_CONFIG_FILE"
  log "  branches: $value"
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

# skill_already_present <dest_file> <name> — returns 0 if the skill sentinel exists in the file
skill_already_present() {
  local dest_file="$1" name="$2"
  [[ -f "$dest_file" ]] && grep -qF "<!-- agentguard:skill:${name} -->" "$dest_file"
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
      if skill_already_present "$dest_file" "$name"; then
        log "Skill '$name' already present — skipping"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would append skill '$name' → $(basename "$dest_file")"
        appended=$((appended + 1))
      else
        printf '\n\n---\n\n<!-- agentguard:skill:%s -->\n' "$name" >> "$dest_file"
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

  section "Installing Claude Code guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  install_hooks "$dest/hooks"

  # Only write CLAUDE.md if it doesn't already exist — skills are appended once
  # and the sentinel check in append_skills prevents duplicates on re-runs.
  # If the file is missing (first install or after uninstall), write it fresh.
  if [[ ! -f "$dest/CLAUDE.md" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would copy CLAUDE.md → $dest/CLAUDE.md"
    else
      mkdir -p "$dest"
      cp "$SCRIPT_DIR/agents/claude/CLAUDE.md" "$dest/CLAUDE.md"
      ok "CLAUDE.md installed"
    fi
    append_skills "$dest/CLAUDE.md"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "CLAUDE.md already present — skipping base copy, checking skills"
    else
      log "CLAUDE.md already present — skipping base copy"
    fi
    append_skills "$dest/CLAUDE.md"
  fi

  backup_if_exists "$dest/settings.json"
  merge_settings "$dest/settings.json" \
                 "$SCRIPT_DIR/agents/claude/settings.json" \
                 "$dest/settings.json"
  track_installed_agent "claude"
}

install_cli_wrapper() {
  local bin_dir="$HOME/.local/bin"
  local wrapper="$bin_dir/agentguard"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would install agentguard CLI wrapper → $wrapper"
    return
  fi

  mkdir -p "$bin_dir"
  cat > "$wrapper" <<WRAPPER
#!/bin/bash
exec "$SCRIPT_DIR/install.sh" "\$@"
WRAPPER
  chmod +x "$wrapper"
  ok "agentguard CLI installed → $wrapper"

  # Warn if ~/.local/bin is not in PATH
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$bin_dir"; then
    log "Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

install_kiro() {
  local dest="$HOME/.kiro"

  section "Installing Kiro guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  install_hooks "$dest/hooks"

  # Only write KIRO.md if it doesn't already exist — same rationale as CLAUDE.md above.
  if [[ ! -f "$dest/KIRO.md" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would copy KIRO.md → $dest/KIRO.md"
    else
      mkdir -p "$dest"
      cp "$SCRIPT_DIR/agents/kiro/KIRO.md" "$dest/KIRO.md"
      ok "KIRO.md installed"
    fi
    append_skills "$dest/KIRO.md"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "KIRO.md already present — skipping base copy, checking skills"
    else
      log "KIRO.md already present — skipping base copy"
    fi
    append_skills "$dest/KIRO.md"
  fi

  local agent_dest="$dest/agents"
  backup_if_exists "$agent_dest/agentguard.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy agent.json → $agent_dest/agentguard.json"
  else
    mkdir -p "$agent_dest"
    cp "$SCRIPT_DIR/agents/kiro/agent.json" "$agent_dest/agentguard.json"
    ok "agentguard agent config installed → $agent_dest/agentguard.json"
  fi
  track_installed_agent "kiro"
}

install_codex() {
  # Codex reads AGENTS.md from the working directory or home directory.
  # Shell hooks are not supported — AGENTS.md is the only enforcement layer.
  local dest="$HOME"

  section "Installing Codex guardrails → $dest/AGENTS.md"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  # Only write AGENTS.md if it doesn't already exist — same rationale as CLAUDE.md above.
  if [[ ! -f "$dest/AGENTS.md" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would copy AGENTS.md → $dest/AGENTS.md"
    else
      cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$dest/AGENTS.md"
      ok "AGENTS.md installed"
    fi
    append_skills "$dest/AGENTS.md"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "AGENTS.md already present — skipping base copy, checking skills"
    else
      log "AGENTS.md already present — skipping base copy"
    fi
    append_skills "$dest/AGENTS.md"
  fi
  log "Note: Codex does not support shell hooks — instruction file only."
  track_installed_agent "codex"
}

install_cursor() {
  # Cursor reads config from the current project directory (.cursor/).
  local dest
  dest="$(pwd)/.cursor"
  local project_root
  project_root="$(pwd)"
  local src_base
  src_base="$SCRIPT_DIR/agents/cursor"
  local src_cursor
  src_cursor="$src_base/.cursor"
  local src_agents
  src_agents="$src_base/AGENTS.md"

  section "Installing Cursor guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  if [[ ! -d "$src_cursor" ]]; then
    fail "Cursor config not found at $src_cursor"
  fi
  if [[ ! -f "$src_agents" ]]; then
    fail "Cursor AGENTS.md not found at $src_agents"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would install Cursor config → $dest"
    dry "  copy AGENTS.md → $project_root/AGENTS.md (if missing)"
    dry "  copy hooks.json → $dest/hooks.json (if missing)"
    dry "  copy hook scripts from $SCRIPT_DIR/hooks/"
    dry "  append skills → $project_root/AGENTS.md"
    return
  fi

  mkdir -p "$dest/hooks"

  # Cursor instruction file (project-local). Only install if missing.
  if [[ ! -f "$project_root/AGENTS.md" ]]; then
    cp "$src_agents" "$project_root/AGENTS.md"
    ok "AGENTS.md installed → $project_root/AGENTS.md"
  else
    log "AGENTS.md already present — skipping"
  fi

  append_skills "$project_root/AGENTS.md"

  # hooks.json — only install if missing (preserve user edits on re-run)
  if [[ ! -f "$dest/hooks.json" ]]; then
    cp "$src_cursor/hooks.json" "$dest/hooks.json"
    ok "hooks.json installed → $dest/hooks.json"
  else
    log "hooks.json already present — skipping"
  fi

  # Hook scripts are shared with Claude/Kiro; always refresh to pick up updates.
  install_hooks "$dest/hooks"

  ok "Cursor config installed → $dest"
  # Cursor is project-local — not tracked for upgrade (no single home dir to reinstall to).
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

# remove_agentguard_config — removes ~/.agentguard/config written by install.sh.
# Removes the directory too if it is empty afterwards.
remove_agentguard_config() {
  local cfg_file="$HOME/.agentguard/config"
  local cfg_dir="$HOME/.agentguard"
  if [[ -f "$cfg_file" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would remove $cfg_file"
    else
      rm "$cfg_file"
      ok "Removed $cfg_file"
      # Remove the directory only if it is now empty.
      if [[ -d "$cfg_dir" ]] && [[ -z "$(ls -A "$cfg_dir")" ]]; then
        rmdir "$cfg_dir"
        log "Removed empty directory $cfg_dir"
      fi
    fi
  else
    log "~/.agentguard/config not found (already removed?)"
  fi
}

# ── version checking & upgrade ───────────────────────────────────────────────

# check_for_update — fetches latest GitHub release tag and prints a notice if
# a newer version is available. Silently skips if curl is absent or offline.
check_for_update() {
  command -v curl >/dev/null 2>&1 || return 0
  [[ "$AGENTGUARD_VERSION" == "unknown" ]] && return 0

  local latest
  latest=$(curl -sf --max-time 3 \
    "https://api.github.com/repos/SumonMSelim/agentguard/releases/latest" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/') || return 0
  [[ -z "$latest" ]] && return 0

  # Simple semver comparison: split on dots, compare numerically field by field.
  _semver_gt() {
    local a="$1" b="$2"
    IFS='.' read -r a1 a2 a3 <<< "$a"
    IFS='.' read -r b1 b2 b3 <<< "$b"
    [[ "${a1:-0}" -gt "${b1:-0}" ]] && return 0
    [[ "${a1:-0}" -eq "${b1:-0}" && "${a2:-0}" -gt "${b2:-0}" ]] && return 0
    [[ "${a1:-0}" -eq "${b1:-0}" && "${a2:-0}" -eq "${b2:-0}" && "${a3:-0}" -gt "${b3:-0}" ]] && return 0
    return 1
  }

  if _semver_gt "$latest" "$AGENTGUARD_VERSION"; then
    echo ""
    printf "${_C_YELLOW}${_C_BOLD}  ┌─────────────────────────────────────────────────────────┐${_C_RESET}\n"
    local _pad=$(( 21 - ${#AGENTGUARD_VERSION} - ${#latest} ))
    [[ "$_pad" -lt 1 ]] && _pad=1
    printf "${_C_YELLOW}${_C_BOLD}  │  [UPDATE]  agentguard v%s → v%s available%*s│${_C_RESET}\n" \
      "$AGENTGUARD_VERSION" "$latest" "$_pad" ""
    printf "${_C_YELLOW}${_C_BOLD}  │  Run: agentguard upgrade                                │${_C_RESET}\n"
    printf "${_C_YELLOW}${_C_BOLD}  └─────────────────────────────────────────────────────────┘${_C_RESET}\n"
  fi
}

# track_installed_agent <agent> — persists agent name to config so upgrade
# knows which agents to reinstall. Idempotent.
track_installed_agent() {
  local agent="$1"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$AGENTGUARD_CONFIG_DIR"

  local current=""
  if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
    current=$(grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
              | tail -n1 \
              | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//') || true
  fi

  # Add agent if not already listed.
  if ! echo " $current " | grep -qF " $agent "; then
    local updated
    updated=$(echo "$current $agent" | tr -s ' ' | sed 's/^ //; s/ $//')
    # Write or replace the AGENTGUARD_INSTALLED_AGENTS line.
    if grep -q '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" 2>/dev/null; then
      local tmp
      tmp=$(mktemp)
      grep -v '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" > "$tmp"
      echo "AGENTGUARD_INSTALLED_AGENTS=\"$updated\"" >> "$tmp"
      mv "$tmp" "$AGENTGUARD_CONFIG_FILE"
    else
      mkdir -p "$AGENTGUARD_CONFIG_DIR"
      echo "AGENTGUARD_INSTALLED_AGENTS=\"$updated\"" >> "$AGENTGUARD_CONFIG_FILE"
    fi
  fi
}

# untrack_installed_agent <agent> — removes agent from the tracked list.
untrack_installed_agent() {
  local agent="$1"
  [[ -f "$AGENTGUARD_CONFIG_FILE" ]] || return 0

  local current
  current=$(grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
            | tail -n1 \
            | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//') || true

  local updated
  # grep -v exits 1 when no lines pass (last agent removed) — suppress with ||true.
  updated=$(echo "$current" | tr ' ' '\n' | { grep -v "^${agent}$" || true; } | tr '\n' ' ' | sed 's/^ //; s/ $//')

  local tmp
  tmp=$(mktemp)
  grep -v '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" > "$tmp"
  [[ -n "$updated" ]] && echo "AGENTGUARD_INSTALLED_AGENTS=\"$updated\"" >> "$tmp"
  mv "$tmp" "$AGENTGUARD_CONFIG_FILE"
}

# do_upgrade — pulls latest agentguard from git, then reinstalls all
# previously tracked agents.
do_upgrade() {
  section "agentguard upgrade"

  # Verify this script lives inside a git repo (it should — it's the clone).
  if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    fail "Cannot upgrade: $SCRIPT_DIR is not a git repository. Clone agentguard to upgrade."
  fi

  log "Pulling latest agentguard from origin..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would run: git -C $SCRIPT_DIR pull --ff-only"
  else
    git -C "$SCRIPT_DIR" pull --ff-only || fail "git pull failed. Resolve conflicts manually."
    ok "Repository updated"
  fi

  # Re-read version after pull.
  local new_version
  new_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")

  # Read tracked agents from config.
  local tracked=""
  if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
    tracked=$(grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
              | tail -n1 \
              | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//') || true
  fi

  if [[ -z "$tracked" ]]; then
    warn "No tracked agent installations found in $AGENTGUARD_CONFIG_FILE."
    log "Run './install.sh <agent>' to install and start tracking."
    exit 0
  fi

  echo ""
  log "Reinstalling tracked agents: $tracked"
  for agent in $tracked; do
    section "── $agent ──"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would uninstall $agent then reinstall $agent"
    else
      bash "$SCRIPT_DIR/install.sh" uninstall "$agent"
      echo ""
      bash "$SCRIPT_DIR/install.sh" "$agent"
    fi
  done

  echo ""
  ok "Upgrade complete → agentguard v$new_version"
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

  section "Uninstalling Claude Code guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_file  "$dest/CLAUDE.md"
  unmerge_settings "$dest/settings.json" "$SCRIPT_DIR/agents/claude/settings.json"
  remove_file  "$HOME/.local/bin/agentguard"
  untrack_installed_agent "claude"
}

uninstall_kiro() {
  local dest="$HOME/.kiro"

  section "Uninstalling Kiro guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_file  "$dest/KIRO.md"
  remove_file  "$dest/agents/agentguard.json"
  untrack_installed_agent "kiro"
}

uninstall_codex() {
  local dest="$HOME"

  section "Uninstalling Codex guardrails from $dest/AGENTS.md"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_file "$dest/AGENTS.md"
  log "Note: no hooks to remove — Codex is instruction-file only."
  untrack_installed_agent "codex"
}

CURSOR_AGENTGUARD_FILES=(
  ".cursor/hooks.json"
  ".cursor/hooks/audit-log.sh"
  ".cursor/hooks/block-destructive-ops.sh"
  ".cursor/hooks/block-env-read.sh"
  ".cursor/hooks/block-env.sh"
  ".cursor/hooks/block-main-branch.sh"
  ".cursor/hooks/block-system-installs.sh"
  ".cursor/rules/karpathy-guidelines.mdc"
  ".cursor/skills/karpathy-guidelines/SKILL.md"
)

uninstall_cursor() {
  local dest
  dest="$(pwd)"
  local src_agents
  src_agents="$SCRIPT_DIR/agents/cursor/AGENTS.md"

  section "Uninstalling Cursor guardrails from $dest/.cursor"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  # Remove AGENTS.md only if agentguard owns it: the file must start with our
  # canonical header (skills may have been appended after, so exact match fails).
  if [[ -f "$dest/AGENTS.md" && -f "$src_agents" ]]; then
    local src_lines
    src_lines=$(wc -l < "$src_agents")
    if diff -q <(head -n "$src_lines" "$dest/AGENTS.md") "$src_agents" >/dev/null 2>&1; then
      backup_if_exists "$dest/AGENTS.md"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would remove $dest/AGENTS.md"
      else
        rm "$dest/AGENTS.md"
        log "Removed $dest/AGENTS.md"
      fi
    else
      log "AGENTS.md present but not owned by agentguard — leaving in place"
    fi
  fi

  local removed=0
  for rel in "${CURSOR_AGENTGUARD_FILES[@]}"; do
    local f="$dest/$rel"
    if [[ -f "$f" ]]; then
      backup_if_exists "$f"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would remove $f"
      else
        rm "$f"
        log "Removed $f"
      fi
      removed=$((removed + 1))
    fi
  done

  if [[ "$DRY_RUN" -eq 0 ]]; then
    rmdir "$dest/.cursor/hooks" 2>/dev/null || true
    rmdir "$dest/.cursor/rules" 2>/dev/null || true
    rmdir "$dest/.cursor/skills/karpathy-guidelines" 2>/dev/null || true
    rmdir "$dest/.cursor/skills" 2>/dev/null || true
    rmdir "$dest/.cursor" 2>/dev/null || true
  fi

  if [[ "$removed" -eq 0 ]]; then
    log "No Cursor guardrail files found (already removed?)"
  elif [[ "$DRY_RUN" -eq 0 ]]; then
    ok "Cursor guardrail files removed"
  fi
}

# ── check ─────────────────────────────────────────────────────────────────────
#
# Reports whether the installation matches expected state. No writes.
# Exits 0 if all checks pass, 1 if any issues found.

_check_issues=0

_check_ok()   { printf "${_C_GREEN}  [OK]${_C_RESET}      %s\n" "$*"; }
_check_fail() { printf "${_C_RED}  [MISSING]${_C_RESET} %s\n" "$*"; _check_issues=$((_check_issues + 1)); }

# check_hooks <hooks_dir>
check_hooks() {
  local dir="$1"
  local missing=0
  for hook in "${AGENTGUARD_HOOKS[@]}"; do
    [[ -f "$dir/$hook" ]] || missing=$((missing + 1))
  done
  if [[ "$missing" -eq 0 ]]; then
    _check_ok "hooks: all ${#AGENTGUARD_HOOKS[@]} present ($dir)"
  else
    _check_fail "hooks: $missing of ${#AGENTGUARD_HOOKS[@]} missing from $dir"
    for hook in "${AGENTGUARD_HOOKS[@]}"; do
      [[ -f "$dir/$hook" ]] || printf '      missing: %s\n' "$hook"
    done
  fi
}

# check_file <path> <label>
check_file() {
  local f="$1" label="$2"
  if [[ -f "$f" ]]; then
    _check_ok "$label present ($f)"
  else
    _check_fail "$label not found ($f)"
  fi
}

# check_settings <settings_path> <guardrails_path>
check_settings() {
  local settings="$1"
  local guardrails="$2"

  if [[ ! -f "$settings" ]]; then
    _check_fail "settings.json not found ($settings)"
    return
  fi

  require jq

  local guard_json
  guard_json=$(cat "$guardrails")

  # Check required hook commands
  local missing_hooks=()
  while IFS= read -r cmd; do
    if ! jq -e --arg cmd "$cmd" '
      [.hooks.PreToolUse[]?.hooks[]?.command,
       .hooks.PostToolUse[]?.hooks[]?.command] | index($cmd) != null
    ' "$settings" >/dev/null 2>&1; then
      missing_hooks+=("$cmd")
    fi
  done < <(echo "$guard_json" | jq -r '
    [.hooks.PreToolUse[]?.hooks[]?.command,
     .hooks.PostToolUse[]?.hooks[]?.command] | unique[]
  ')

  if [[ "${#missing_hooks[@]}" -eq 0 ]]; then
    _check_ok "settings.json: all hook commands registered"
  else
    _check_fail "settings.json: ${#missing_hooks[@]} hook command(s) missing"
    for cmd in "${missing_hooks[@]}"; do
      printf '      missing: %s\n' "$cmd"
    done
  fi

  # Check security-critical scalars
  local scalar_issues=()
  while IFS=$'\t' read -r key expected; do
    local actual
    actual=$(jq -r --arg k "$key" '.[$k] | tostring' "$settings" 2>/dev/null || echo "null")
    [[ "$actual" == "$expected" ]] || scalar_issues+=("$key: expected $expected, got $actual")
  done < <(echo "$guard_json" | jq -r '
    to_entries
    | map(select(.key | IN("includeCoAuthoredBy","gitAttribution","disableGitWorkflow")))
    | .[]
    | [.key, (.value | tostring)]
    | @tsv
  ')

  if [[ "${#scalar_issues[@]}" -eq 0 ]]; then
    _check_ok "settings.json: security scalars correct"
  else
    _check_fail "settings.json: scalar mismatch"
    for issue in "${scalar_issues[@]}"; do
      printf '      %s\n' "$issue"
    done
  fi
}

check_claude() {
  local dest="$HOME/.claude"
  section "Checking Claude Code installation → $dest"
  check_hooks   "$dest/hooks"
  check_file    "$dest/CLAUDE.md" "CLAUDE.md"
  check_settings "$dest/settings.json" "$SCRIPT_DIR/agents/claude/settings.json"
  check_exec    "$HOME/.local/bin/agentguard" "agentguard CLI"
  echo ""
}

check_kiro() {
  local dest="$HOME/.kiro"
  section "Checking Kiro installation → $dest"
  check_hooks  "$dest/hooks"
  check_file   "$dest/KIRO.md" "KIRO.md"
  check_file   "$dest/agents/agentguard.json" "agentguard.json"
  echo ""
}

check_codex() {
  local dest="$HOME"
  section "Checking Codex installation → $dest"
  check_file "$dest/AGENTS.md" "AGENTS.md"
  echo ""
}

check_exec() {
  local f="$1" label="$2"
  if [[ -f "$f" && -x "$f" ]]; then
    _check_ok "$label executable ($f)"
  elif [[ -f "$f" ]]; then
    _check_fail "$label not executable ($f)"
  else
    _check_fail "$label not found ($f)"
  fi
}

check_cursor() {
  local dest
  dest="$(pwd)/.cursor"
  section "Checking Cursor installation → $dest"
  check_file "$(pwd)/AGENTS.md" "AGENTS.md"
  check_file "$dest/hooks.json" "hooks.json"
  check_exec "$dest/hooks/audit-log.sh" "audit-log.sh"
  check_exec "$dest/hooks/block-destructive-ops.sh" "block-destructive-ops.sh"
  check_exec "$dest/hooks/block-system-installs.sh" "block-system-installs.sh"
  check_exec "$dest/hooks/block-env.sh" "block-env.sh"
  check_exec "$dest/hooks/block-main-branch.sh" "block-main-branch.sh"
  check_exec "$dest/hooks/block-env-read.sh" "block-env-read.sh"
  echo ""
}

# ── project-level installers ─────────────────────────────────────────────────
#
# --project appends skills only to the instruction file in the current working
# directory. No hooks, no settings.json — those are global-only.
#
#   Claude: .claude/CLAUDE.md  (created if absent)
#   Codex:  AGENTS.md          (created if absent)
#   Cursor: always project-local — --project runs full install instead
#   Kiro:   not supported      (prints warning, exits 0)

install_project_claude() {
  local dest
  dest="$(pwd)/.claude"
  local file="$dest/CLAUDE.md"

  section "Installing Claude Code project skills → $file"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  if [[ ! -f "$file" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would create $file (empty)"
    else
      mkdir -p "$dest"
      touch "$file"
      ok "Created $file"
    fi
  else
    log "$file already exists — appending skills only"
  fi

  append_skills "$file"
}

install_project_codex() {
  local file
  file="$(pwd)/AGENTS.md"

  section "Installing Codex project skills → $file"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  if [[ ! -f "$file" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would create $file (empty)"
    else
      touch "$file"
      ok "Created $file"
    fi
  else
    log "$file already exists — appending skills only"
  fi

  append_skills "$file"
}

install_project_kiro() {
  warn "Kiro does not support per-project instruction files." >&2
  log  "Kiro's agent.json references a single global file (~/.kiro/KIRO.md)." >&2
  log  "Install skills globally instead: ./install.sh kiro --skills <list>" >&2
}

# ── entry point ───────────────────────────────────────────────────────────────

if [[ "$UPGRADE" -eq 1 ]]; then
  do_upgrade
  echo ""
  ok "Done."
  [[ "$DRY_RUN" -eq 1 ]] && dry "no files were changed"
  exit 0
fi

if [[ "$CHECK" -eq 1 ]]; then
  case "$AGENT" in
    claude) check_claude ;;
    codex)  check_codex  ;;
    kiro)   check_kiro   ;;
    cursor) check_cursor ;;
    all)    check_claude; check_codex; check_kiro; check_cursor ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | all" ;;
  esac
  if [[ "$_check_issues" -eq 0 ]]; then
    ok "All checks passed."
    check_for_update
    exit 0
  else
    warn "$_check_issues issue(s) found. Run './install.sh [agent]' to fix."
    check_for_update
    exit 1
  fi
fi

if [[ "$UNINSTALL" -eq 1 ]]; then
  case "$AGENT" in
    claude) uninstall_claude ;;
    codex)  uninstall_codex  ;;
    kiro)   uninstall_kiro   ;;
    cursor) uninstall_cursor ;;
    all)    uninstall_claude; echo; uninstall_codex; echo; uninstall_kiro; echo; uninstall_cursor; echo; remove_agentguard_config ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | all" ;;
  esac
  echo ""
  ok "Done."
  [[ "$DRY_RUN" -eq 1 ]] && dry "no files were changed"
  exit 0
fi

if [[ "$PROJECT" -eq 1 ]]; then
  case "$AGENT" in
    claude) install_project_claude ;;
    codex)  install_project_codex  ;;
    cursor) log "Cursor is always project-local — running full install instead"; install_cursor ;;
    kiro)   install_project_kiro   ;;
    all)    install_project_claude; echo; install_project_codex; echo; install_project_kiro ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | cursor | kiro | all" ;;
  esac
  echo ""
  ok "Done."
  [[ "$DRY_RUN" -eq 1 ]] && dry "no files were written"
  exit 0
fi

# codex is instruction-only (no hooks), so protected-branch config is irrelevant.
# upgrade reuses existing config — skip prompt to avoid interrupting the reinstall loop.
[[ "$AGENT" != "codex" && "$UPGRADE" -eq 0 ]] && prompt_protected_branches

case "$AGENT" in
  claude) install_claude ;;
  codex)  install_codex  ;;
  kiro)   install_kiro   ;;
  cursor) install_cursor ;;
  all)    install_claude; echo; install_codex; echo; install_kiro; echo; install_cursor ;;
  *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | all" ;;
esac

install_cli_wrapper

echo ""
ok "Done."
[[ "$DRY_RUN" -eq 1 ]] && dry "no files were written"
[[ "$AGENT" == "kiro" || "$AGENT" == "all" ]] && [[ "$DRY_RUN" -eq 0 ]] && \
  log "Switch to the 'agentguard' agent in Kiro to activate guardrails."
exit 0
