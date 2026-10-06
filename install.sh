#!/bin/bash
# install.sh
#
# Installs (or uninstalls) AI agent guardrails to their tool-specific config locations.
# Also installs an `agentguard` CLI wrapper to ~/.local/bin/ so you can run
# `agentguard <cmd>` from any directory after the initial install.
#
# Preferred usage (after the `agentguard` CLI wrapper is installed):
#   agentguard [claude|codex|kiro|cursor|grok|all]
#   agentguard uninstall ...
#   agentguard check ...
#   agentguard upgrade
#
# Bootstrap from a fresh clone (one time only, installs the wrapper):
#   ./install.sh claude   # then use `agentguard` for all future commands
#
#   --skills <list>        — comma-separated skill names to append (e.g. karpathy-guidelines)
#                            Skills tagged [core] are always appended unless --skills none
#   --dry-run              — show what would be changed without writing anything
#   --project              — append skills to the project-level instruction file in CWD
#                            Claude: .claude/CLAUDE.md  Codex: AGENTS.md  Kiro: not supported
#   --user                 — Cursor only: install hooks to ~/.cursor/ (all projects) instead of CWD
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
DISABLE_CMD=0
ENABLE_CMD=0
STATUS_CMD=0
TARGET_DIR=""
CURSOR_USER=0

# Detect subcommands (can be invoked as `agentguard` or directly as ./install.sh for bootstrap)
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
elif [[ "$AGENT" == "disable" ]]; then
  DISABLE_CMD=1
  shift || true
elif [[ "$AGENT" == "enable" ]]; then
  ENABLE_CMD=1
  shift || true
elif [[ "$AGENT" == "status" ]]; then
  STATUS_CMD=1
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
  if [[ "${args[$i]}" == "--user" ]]; then
    CURSOR_USER=1
  fi
  # disable/enable/status take an optional path: the first non-flag argument.
  if [[ $((DISABLE_CMD + ENABLE_CMD + STATUS_CMD)) -gt 0 && -z "$TARGET_DIR" && "${args[$i]}" != --* ]]; then
    TARGET_DIR="${args[$i]}"
  fi
done

# If the first positional arg is a flag (e.g. agentguard --dry-run or direct ./install.sh), default agent to claude
if [[ "$AGENT" == --* ]]; then
  AGENT="claude"
fi

# A user-level Cursor install is tracked as "cursor-user" so upgrade can re-run it by name.
if [[ "$AGENT" == "cursor-user" ]]; then
  AGENT="cursor"
  CURSOR_USER=1
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
# Upgrade (AGENTGUARD_UPGRADE=1) with a saved value: no prompt, no write.
# Only the AGENTGUARD_PROTECTED_BRANCHES line is replaced; other config
# lines (e.g. AGENTGUARD_INSTALLED_AGENTS) are preserved.

AGENTGUARD_CONFIG_DIR="$HOME/.agentguard"
AGENTGUARD_CONFIG_FILE="$AGENTGUARD_CONFIG_DIR/config"
# What install_claude added to ~/.claude/settings.json; read by unmerge_settings.
AGENTGUARD_CLAUDE_RECORD="$AGENTGUARD_CONFIG_DIR/claude-added.json"
DEFAULT_PROTECTED_BRANCHES="main,master"

prompt_protected_branches() {
  local default="$DEFAULT_PROTECTED_BRANCHES"

  # If a previous install wrote a value, use it as the new default.
  local prev=""
  if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
    prev=$(grep -E '^AGENTGUARD_PROTECTED_BRANCHES=' "$AGENTGUARD_CONFIG_FILE" \
           | tail -n1 \
           | sed -E 's/^AGENTGUARD_PROTECTED_BRANCHES=//; s/^"//; s/"$//') || true
    [[ -n "$prev" ]] && default="$prev"
  fi

  # Upgrade reinstalls reuse the saved value — no prompt, no rewrite.
  if [[ "${AGENTGUARD_UPGRADE:-0}" == "1" && -n "$prev" ]]; then
    log "Upgrade — keeping protected branches: $prev"
    return
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
  # Replace only our own line; keep every other line of an existing config.
  local tmp
  tmp=$(mktemp)
  if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
    grep -v '^AGENTGUARD_PROTECTED_BRANCHES=' "$AGENTGUARD_CONFIG_FILE" > "$tmp" || true
  else
    cat > "$tmp" <<'EOF'
# agentguard config — written by install.sh
# Parsed (not sourced) by hooks/block-main-branch.sh when
# AGENTGUARD_PROTECTED_BRANCHES is not already set in the environment.
EOF
  fi
  echo "AGENTGUARD_PROTECTED_BRANCHES=\"$value\"" >> "$tmp"
  mv "$tmp" "$AGENTGUARD_CONFIG_FILE"
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
#   Security-critical keys
#     (attribution, includeGitInstructions)
#     Guardrails value always wins. Verified against
#     code.claude.com/docs/en/settings-reference: attribution.commit/.pr are
#     strings ("" hides them); includeCoAuthoredBy is "Deprecated since
#     v2.0.62, when attribution replaced it"; gitAttribution and
#     disableGitWorkflow are not settings keys. Our old values of those three
#     are removed on merge.
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

  # Refuse to merge into a file jq cannot parse — leave it untouched.
  if [[ -f "$existing" ]] && ! jq empty "$existing"; then
    fail "$existing is not valid JSON — fix it and re-run. File left unchanged."
  fi

  local user_json='{}'
  [[ -f "$existing" ]] && user_json=$(cat "$existing")
  local guard_json
  guard_json=$(cat "$guardrails")

  jq -n \
    --argjson user  "$user_json" \
    --argjson guard "$guard_json" \
    '
    # User entries first, in their order; ours appended if not present.
    def union_arr(a; b):
      reduce ((a // []) + (b // []))[] as $x ([]; if index($x) == null then . + [$x] else . end);

    # Known-stale entries removed from guardrails over time. Pruned from the
    # user deny array before unioning so upgrades self-heal instead of
    # carrying dead/broken rules forward forever.
    def stale_deny: ["Write(~/.agentguard/**)", "Read(./.env)", "Read(./.env.*)"];
    def prune_stale(a): (a // []) - stale_deny;
    # Over-broad allow rules shipped before #66.
    def stale_allow: ["Read(**)", "Bash(ssh *)", "Bash(find *)", "Bash(docker *)", "Bash(cat *)", "Bash(curl *)"];
    def prune_stale_allow(a): (a // []) - stale_allow;

    # Per-tool matchers for block-env-read.sh shipped before #67. Strip our
    # command from them (the combined matcher replaces them); drop the block
    # only if nothing of the user is left in it.
    def stale_matchers: ["Read", "Write", "Edit", "MultiEdit"];
    def prune_stale_hooks(arr):
      arr | map(
        if ((.matcher // "") as $m | stale_matchers | index($m)) != null then
          .hooks = ((.hooks // []) | map(select(.command != "bash ~/.claude/hooks/block-env-read.sh")))
          | select(.hooks | length > 0)
        else . end
      );

    # Remove a legacy key only if it still holds the value we wrote.
    def drop_if(k; v): if .[k] == v then del(.[k]) else . end;

    # Merge PreToolUse hook arrays.
    # For each guardrail matcher block:
    #   - if the user has the same matcher, append our hooks (dedup by command)
    #   - if not, add the entire block
    # A missing matcher is treated as "". User hooks are kept verbatim and in
    # order; ours are appended only when no hook with that command exists yet.
    def merge_hooks(uarr; garr):
      (garr | map({(.matcher // ""): .hooks}) | add // {}) as $gi |
      (uarr | map(
        (.matcher // "") as $m |
        if ($gi | has($m)) then
          .hooks = reduce $gi[$m][] as $h ((.hooks // []);
            if any(.[]; .command == $h.command) then . else . + [$h] end)
        else . end
      )) +
      (garr | map(select(
        (.matcher // "") as $gm |
        (uarr | map(.matcher // "") | index($gm)) == null
      )));

    # Start from the user object so all personal keys are preserved,
    # then apply targeted guardrail overrides.
    $user
    | .permissions.allow       = union_arr(prune_stale_allow($user.permissions.allow); $guard.permissions.allow)
    | .permissions.ask         = union_arr($user.permissions.ask;         $guard.permissions.ask)
    | .permissions.deny        = union_arr(prune_stale($user.permissions.deny); $guard.permissions.deny)
    | .permissions.defaultMode = ($user.permissions.defaultMode // $guard.permissions.defaultMode // "acceptEdits")
    | .hooks.PreToolUse        = merge_hooks(
                                   prune_stale_hooks($user.hooks.PreToolUse // []);
                                   ($guard.hooks.PreToolUse // [])
                                 )
    | .hooks.PostToolUse       = merge_hooks(
                                   ($user.hooks.PostToolUse  // []);
                                   ($guard.hooks.PostToolUse // [])
                                 )
    | .attribution             = $guard.attribution
    | .includeGitInstructions  = $guard.includeGitInstructions
    | drop_if("includeCoAuthoredBy"; false)
    | drop_if("gitAttribution"; false)
    | drop_if("disableGitWorkflow"; true)
    ' > "${output}.tmp.$$" || {
      rm -f "${output}.tmp.$$"
      fail "settings.json merge failed — $output left unchanged."
    }
  mv "${output}.tmp.$$" "$output"

  ok "settings.json merged → $output"
}

# record_claude_added <existing_settings> <guardrails>
#
# Writes $AGENTGUARD_CLAUDE_RECORD before merge_settings runs, so uninstall can
# undo exactly what this install changes:
#   {"allow":[...],"ask":[...],"deny":[...],   entries we add (ours minus user's)
#    "defaultMode":true|false,                 true if we set permissions.defaultMode
#    "scalars":{"attribution":<prev|null>,"includeGitInstructions":<prev|null>},
#    "hadHooks":true|false}                    whether the user had a hooks key
# On a re-install the previous record is kept and extended. A settings file
# that already holds our hooks but has no record (installed by an older
# version) gets no record; unmerge_settings then falls back to stripping.
record_claude_added() {
  local existing="$1"
  local guardrails="$2"

  [[ "$DRY_RUN" -eq 1 ]] && return 0
  # Invalid JSON: merge_settings refuses it and fails; nothing to record.
  if [[ -f "$existing" ]] && ! jq empty "$existing" 2>/dev/null; then
    return 0
  fi

  local user_json='{}' old_json='null'
  [[ -f "$existing" ]] && user_json=$(cat "$existing")
  if [[ -f "$AGENTGUARD_CLAUDE_RECORD" ]] && jq empty "$AGENTGUARD_CLAUDE_RECORD" 2>/dev/null; then
    old_json=$(cat "$AGENTGUARD_CLAUDE_RECORD")
  fi

  local cmds='[.hooks.PreToolUse, .hooks.PostToolUse | .[]? | .hooks[]?.command]'
  if [[ "$old_json" == "null" ]] \
     && jq -e --argjson g "$(jq "$cmds" "$guardrails")" \
          "$cmds | any(. as \$c | \$g | index(\$c) != null)" <<<"$user_json" >/dev/null; then
    log "settings.json has agentguard hooks but no install record — uninstall will strip by match"
    return 0
  fi

  mkdir -p "$AGENTGUARD_CONFIG_DIR"
  jq -n \
    --argjson user  "$user_json" \
    --argjson guard "$(cat "$guardrails")" \
    --argjson old   "$old_json" \
    '
    def added(k): (($old[k] // []) + (($guard.permissions[k] // []) - ($user.permissions[k] // []))) | unique;
    {
      allow: added("allow"),
      ask:   added("ask"),
      deny:  added("deny"),
      defaultMode: (($old.defaultMode // false) or ($user.permissions.defaultMode == null)),
      scalars: ($old.scalars // {
        attribution:            $user.attribution,
        includeGitInstructions: $user.includeGitInstructions
      }),
      hadHooks: (if $old == null then ($user | has("hooks")) else $old.hadHooks end)
    }
    ' > "${AGENTGUARD_CLAUDE_RECORD}.tmp.$$" || {
      rm -f "${AGENTGUARD_CLAUDE_RECORD}.tmp.$$"
      fail "Could not write $AGENTGUARD_CLAUDE_RECORD"
    }
  mv "${AGENTGUARD_CLAUDE_RECORD}.tmp.$$" "$AGENTGUARD_CLAUDE_RECORD"
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

# Appended to an instruction file only when agentguard created it, so uninstall
# can tell our files apart from user-authored ones it merely appended skills to.
AGENTGUARD_CREATED_MARKER='<!-- agentguard:created -->'

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
        {
          printf '\n\n---\n\n<!-- agentguard:skill:%s -->\n' "$name"
          strip_frontmatter "$skill_dir/SKILL.md"
          printf '<!-- agentguard:end-skill:%s -->\n' "$name"
        } >> "$dest_file"
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
      echo "$AGENTGUARD_CREATED_MARKER" >> "$dest/CLAUDE.md"
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
  record_claude_added "$dest/settings.json" "$SCRIPT_DIR/agents/claude/settings.json"
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

  # A Homebrew install runs from a versioned Cellar path that `brew upgrade`
  # deletes. Point the wrapper at the stable opt symlink instead.
  local target_dir="$SCRIPT_DIR"
  if [[ "$target_dir" == */Cellar/agentguard/*/libexec ]]; then
    target_dir="${target_dir%%/Cellar/agentguard/*}/opt/agentguard/libexec"
  fi

  mkdir -p "$bin_dir"
  cat > "$wrapper" <<WRAPPER
#!/bin/bash
exec "$target_dir/install.sh" "\$@"
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
      echo "$AGENTGUARD_CREATED_MARKER" >> "$dest/KIRO.md"
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

# Codex reads global instructions from its home dir (~/.codex unless CODEX_HOME
# is set) and lifecycle hooks from ~/.codex/hooks.json, which takes
# Claude-shaped PreToolUse/PostToolUse entries. Hooks are on by default but run
# only after the user trusts them with /hooks in Codex.
# Ref: learn.chatgpt.com/docs/hooks, learn.chatgpt.com/docs/agent-configuration/agents-md
CODEX_DIR="$HOME/.codex"

# codex_legacy_owned <file> — returns 0 if <file> (a pre-#69 ~/AGENTS.md) was
# created by agentguard: created marker, current canonical content, or the old
# canonical content that carried a 3-line Codex header on lines 3-5.
codex_legacy_owned() {
  local f="$1" src="$SCRIPT_DIR/agents/codex/AGENTS.md" n
  grep -qxF "$AGENTGUARD_CREATED_MARKER" "$f" && return 0
  n=$(wc -l < "$src")
  diff -q <(head -n "$n" "$f") "$src" >/dev/null 2>&1 && return 0
  sed -n '3p' "$f" | grep -q '^> Codex instruction file' \
    && diff -q <(sed '3,5d' "$f" | head -n "$n") "$src" >/dev/null 2>&1
}

# migrate_codex_legacy_agents_md — older releases installed Codex rules to
# ~/AGENTS.md, which Codex does not read globally. Move an agentguard-created
# copy (with its skills) to ~/.codex/AGENTS.md and remove it. Left alone while
# grok is installed, since grok still reads ~/AGENTS.md.
migrate_codex_legacy_agents_md() {
  local legacy="$HOME/AGENTS.md" dest="$CODEX_DIR/AGENTS.md"
  [[ -f "$legacy" ]] || return 0
  if is_agent_tracked "grok"; then
    log "$legacy still used by grok — leaving in place"
    return 0
  fi
  codex_legacy_owned "$legacy" || return 0

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would migrate $legacy → $dest"
    return 0
  fi
  if [[ ! -f "$dest" ]]; then
    local skills
    skills=$(skills_in_file "$legacy")
    mkdir -p "$CODEX_DIR"
    cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$dest"
    echo "$AGENTGUARD_CREATED_MARKER" >> "$dest"
    # Carry over exactly the skills the legacy file had (append_skills reads SKILLS_ARG).
    local SKILLS_ARG="${skills:-none}"
    append_skills "$dest"
    ok "Migrated $legacy → $dest"
  fi
  remove_file "$legacy"
}

# merge_codex_hooks <dest> — writes our hooks.json entries into <dest>, keeping
# any user hooks. Our entries are appended per event, skipping commands that
# are already registered, so re-runs are idempotent.
merge_codex_hooks() {
  local dest="$1" src="$SCRIPT_DIR/agents/codex/hooks.json"
  require jq
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would register hooks → $dest"
    return
  fi
  if [[ ! -f "$dest" ]]; then
    cp "$src" "$dest"
    ok "Codex hooks registered → $dest"
    return
  fi
  jq empty "$dest" || fail "$dest is not valid JSON — fix it and re-run. File left unchanged."
  backup_if_exists "$dest"
  jq --slurpfile g "$src" '
    reduce ($g[0].hooks | to_entries[]) as $e (.;
      .hooks[$e.key] = ((.hooks[$e.key] // []) as $cur
        | [$cur[].hooks[]?.command] as $have
        | $cur + ($e.value
            | map(.hooks |= map(select(.command as $c | $have | index($c) | not)))
            | map(select(.hooks | length > 0)))))
  ' "$dest" > "${dest}.tmp.$$" || { rm -f "${dest}.tmp.$$"; fail "hooks.json merge failed — $dest left unchanged."; }
  mv "${dest}.tmp.$$" "$dest"
  ok "Codex hooks merged → $dest"
}

install_codex() {
  local dest="$CODEX_DIR"

  section "Installing Codex guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  migrate_codex_legacy_agents_md

  install_hooks "$dest/hooks"
  merge_codex_hooks "$dest/hooks.json"

  # Only write AGENTS.md if it doesn't already exist — same rationale as CLAUDE.md above.
  if [[ ! -f "$dest/AGENTS.md" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would copy AGENTS.md → $dest/AGENTS.md"
    else
      mkdir -p "$dest"
      cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$dest/AGENTS.md"
      echo "$AGENTGUARD_CREATED_MARKER" >> "$dest/AGENTS.md"
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
  log "Note: Codex runs new hooks only after you trust them. Open Codex and run /hooks to review them."
  track_installed_agent "codex"
}

# cursor_root — the directory holding .cursor/: the CWD (project install) or
# $HOME (--user install, ~/.cursor/hooks.json applies to every project).
cursor_root() {
  if [[ "$CURSOR_USER" -eq 1 ]]; then echo "$HOME"; else pwd; fi
}

# cursor_hooks_json — our hooks.json entries. Project hooks run from the
# project root (.cursor/hooks/x.sh); user hooks run from ~/.cursor, so they get
# absolute paths (audit-log.sh derives its log path from $0).
cursor_hooks_json() {
  local src="$SCRIPT_DIR/agents/cursor/hooks.json"
  if [[ "$CURSOR_USER" -eq 1 ]]; then
    jq --arg p "$HOME/.cursor/hooks/" '.hooks[][].command |= sub("^\\.cursor/hooks/"; $p)' "$src"
  else
    jq . "$src"
  fi
}

# merge_cursor_hooks <dest> — writes our entries into <dest>, keeping user
# entries. Our old entries are dropped first (matched by command), so re-runs
# add no duplicates and pick up changed entries (new events, matchers, flags).
merge_cursor_hooks() {
  local dest="$1" ours
  require jq
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would merge hooks → $dest"
    return
  fi
  ours=$(cursor_hooks_json)
  if [[ ! -f "$dest" ]]; then
    echo "$ours" > "$dest"
    ok "hooks.json installed → $dest"
    return
  fi
  jq empty "$dest" || fail "$dest is not valid JSON — fix it and re-run. File left unchanged."
  backup_if_exists "$dest"
  jq --argjson g "$ours" '
    [$g.hooks[][].command] as $ours
    | .version //= $g.version
    | .hooks = (reduce ($g.hooks | to_entries[]) as $e (
        ((.hooks // {}) | map_values(map(select(.command as $c | $ours | index($c) | not))));
        .[$e.key] = ((.[$e.key] // []) + $e.value))
      | with_entries(select(.value | length > 0)))
  ' "$dest" > "${dest}.tmp.$$" || { rm -f "${dest}.tmp.$$"; fail "hooks.json merge failed — $dest left unchanged."; }
  mv "${dest}.tmp.$$" "$dest"
  ok "hooks.json merged → $dest (user hooks kept)"
}

# unmerge_cursor_hooks <file> — strips our entries; removes the file if only
# ours were in it.
unmerge_cursor_hooks() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    log "$(basename "$f") not found (already removed?)"
    return
  fi
  local stripped
  stripped=$(jq --argjson g "$(cursor_hooks_json)" '
    [$g.hooks[][].command] as $ours
    | .hooks |= ((. // {})
        | map_values(map(select(.command as $c | $ours | index($c) | not)))
        | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  ' "$f") || { warn "$f is not valid JSON — leaving in place"; return; }
  if [[ "$(jq -c 'del(.version)' <<< "$stripped")" == "{}" ]]; then
    remove_file "$f"
    return
  fi
  backup_if_exists "$f"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would strip agentguard hooks from $f"
  else
    echo "$stripped" > "${f}.tmp.$$" && mv "${f}.tmp.$$" "$f"
    ok "agentguard hooks stripped from $f (user hooks kept)"
  fi
}

install_cursor() {
  # Cursor reads config from the current project directory (.cursor/), or
  # from ~/.cursor/ for user-level hooks (--user).
  local dest
  dest="$(cursor_root)/.cursor"
  local project_root
  project_root="$(pwd)"
  local src_base
  src_base="$SCRIPT_DIR/agents/cursor"
  local src_agents
  src_agents="$src_base/AGENTS.md"

  section "Installing Cursor guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  if [[ ! -f "$src_base/hooks.json" ]]; then
    fail "Cursor hooks.json not found at $src_base/hooks.json"
  fi
  if [[ ! -f "$src_agents" ]]; then
    fail "Cursor AGENTS.md not found at $src_agents"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would install Cursor config → $dest"
    if [[ "$CURSOR_USER" -eq 0 ]]; then
      dry "  copy AGENTS.md → $project_root/AGENTS.md (if missing)"
      dry "  append skills → $project_root/AGENTS.md"
    fi
    dry "  merge hooks.json → $dest/hooks.json (user hooks kept)"
    dry "  copy hook scripts from $SCRIPT_DIR/hooks/"
    return
  fi

  mkdir -p "$dest/hooks"

  # Cursor has no user-level instruction file, so --user installs hooks only.
  if [[ "$CURSOR_USER" -eq 1 ]]; then
    log "User-level install: hooks only. Run 'agentguard cursor' in a project for AGENTS.md and skills."
  else
    # Cursor instruction file (project-local). Only install if missing.
    if [[ ! -f "$project_root/AGENTS.md" ]]; then
      cp "$src_agents" "$project_root/AGENTS.md"
      ok "AGENTS.md installed → $project_root/AGENTS.md"
    else
      log "AGENTS.md already present — skipping"
    fi

    append_skills "$project_root/AGENTS.md"
  fi

  # Hook scripts are shared with Claude/Kiro; always refresh to pick up updates.
  install_hooks "$dest/hooks"
  merge_cursor_hooks "$dest/hooks.json"

  ok "Cursor config installed → $dest"
  # Project installs are not tracked for upgrade (no single dir to reinstall to);
  # re-run 'agentguard cursor' in the project to refresh them.
  [[ "$CURSOR_USER" -eq 1 ]] && track_installed_agent "cursor-user"
  return 0
}

install_grok() {
  local dest="$HOME/.grok"

  section "Installing Grok guardrails → $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be written)"

  # Install shared hook scripts to ~/.grok/hooks/
  install_hooks "$dest/hooks"

  # Install Grok-specific hook registration (JSON wires the scripts for PreToolUse etc.)
  local hooks_json_src="$SCRIPT_DIR/agents/grok/hooks.json"
  local hooks_json_dest="$dest/hooks/agentguard.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would copy $hooks_json_src → $hooks_json_dest"
  else
    mkdir -p "$dest/hooks"
    cp "$hooks_json_src" "$hooks_json_dest"
    ok "Grok hooks registered → $hooks_json_dest"
  fi

  # Grok uses AGENTS.md (and variants) for global rules. Reuse the canonical content.
  # Only write if missing (skills append handles re-runs via sentinel).
  if [[ ! -f "$HOME/AGENTS.md" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would copy AGENTS.md → $HOME/AGENTS.md"
    else
      cp "$SCRIPT_DIR/agents/codex/AGENTS.md" "$HOME/AGENTS.md"
      echo "$AGENTGUARD_CREATED_MARKER" >> "$HOME/AGENTS.md"
      ok "AGENTS.md installed → $HOME/AGENTS.md"
    fi
    append_skills "$HOME/AGENTS.md"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "AGENTS.md already present — skipping base copy, checking skills"
    else
      log "AGENTS.md already present — skipping base copy"
    fi
    append_skills "$HOME/AGENTS.md"
  fi

  track_installed_agent "grok"
}

# ── uninstallers ──────────────────────────────────────────────────────────────
#
# Uninstall removes only the files agentguard owns:
#   - Hook scripts in the agent's hooks/ directory (matched by name)
#   - The instruction file (CLAUDE.md / KIRO.md / AGENTS.md) if agentguard
#     created it; otherwise only the agentguard skill sections inside it
#   - The Kiro agent config (agentguard.json)
#   - For Claude: our entries are stripped from settings.json (not deleted wholesale)
#
# Every destructive write is preceded by a backup, same as install.
# --dry-run is fully supported.

# Our hook filenames — used to identify which files to remove
AGENTGUARD_HOOKS=(
  _check-disabled.sh
  audit-log.sh
  block-destructive-ops.sh
  block-env-read.sh
  block-env.sh
  block-main-branch.sh
  block-self-edit.sh
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

# remove_instruction_file <path> <canonical_src> — removes the instruction file
# only if agentguard created it (created marker, or legacy: starts with our
# canonical content). Otherwise strips only the agentguard skill sections and
# leaves the user's own content in place.
remove_instruction_file() {
  local f="$1" src="$2"
  if [[ ! -f "$f" ]]; then
    log "$(basename "$f") not found (already removed?)"
    return
  fi

  if grep -qxF "$AGENTGUARD_CREATED_MARKER" "$f" || \
     { [[ -f "$src" ]] && diff -q <(head -n "$(wc -l < "$src")" "$f") "$src" >/dev/null 2>&1; }; then
    remove_file "$f"
    return
  fi

  if ! grep -q '^<!-- agentguard:skill:' "$f"; then
    log "$(basename "$f") present but not owned by agentguard — leaving in place"
    return
  fi

  backup_if_exists "$f"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would strip agentguard skill sections from $f"
    return
  fi
  # Drop each skill section plus the blank/--- separator written before it.
  # Sections without an end sentinel (older installs) run to the next section or EOF.
  awk '
    /^<!-- agentguard:skill:[^ ]+ -->$/ { pending = ""; skip = 1; next }
    skip && /^<!-- agentguard:end-skill:[^ ]+ -->$/ { skip = 0; next }
    skip { next }
    /^(---)?$/ { pending = pending $0 "\n"; next }
    { printf "%s", pending; pending = ""; print }
    END { printf "%s", pending }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  ok "agentguard skill sections stripped from $f (user content kept)"
}

# is_agent_tracked <agent> — returns 0 if the agent is in AGENTGUARD_INSTALLED_AGENTS.
is_agent_tracked() {
  [[ -f "$AGENTGUARD_CONFIG_FILE" ]] || return 1
  grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
    | tail -n1 \
    | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//' \
    | tr ' ' '\n' | grep -qx "$1"
}

# installed_skills <agent> — prints the comma-separated skill names found in the
# agent's instruction file, so upgrade can re-apply them.
installed_skills() {
  local f
  case "$1" in
    claude) f="$HOME/.claude/CLAUDE.md" ;;
    kiro)   f="$HOME/.kiro/KIRO.md" ;;
    # Fall back to the pre-#69 location so an upgrade keeps the skills it migrates.
    codex)  f="$HOME/.codex/AGENTS.md"; [[ -f "$f" ]] || f="$HOME/AGENTS.md" ;;
    grok)   f="$HOME/AGENTS.md" ;;
    *)      return 0 ;;
  esac
  skills_in_file "$f"
}

# skills_in_file <file> — prints the comma-separated agentguard skill names in <file>.
skills_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  { grep -oE '^<!-- agentguard:skill:[^ ]+ -->$' "$f" || true; } \
    | sed -E 's/^<!-- agentguard:skill:([^ ]+) -->$/\1/' \
    | tr '\n' ',' | sed 's/,$//'
}

# remove_agentguard_config — removes ~/.agentguard/config and the Claude
# install record written by install.sh.
# Removes the directory too if it is empty afterwards.
remove_agentguard_config() {
  local cfg_file="$HOME/.agentguard/config"
  local cfg_dir="$HOME/.agentguard"
  if [[ -f "$AGENTGUARD_CLAUDE_RECORD" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would remove $AGENTGUARD_CLAUDE_RECORD"
    else
      rm "$AGENTGUARD_CLAUDE_RECORD"
      ok "Removed $AGENTGUARD_CLAUDE_RECORD"
    fi
  fi
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

# verify_sha256 <file> <sums_file> <asset_name> — fails unless <file> matches
# the checksum listed for <asset_name> in <sums_file> (sha256sum format).
verify_sha256() {
  local file="$1" sums="$2" name="$3" expected actual
  [[ -s "$sums" ]] || fail "Checksum file missing or empty — refusing to install $name."
  expected=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums")
  [[ -n "$expected" ]] || fail "No checksum for $name in SHA256SUMS — refusing to install."
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  fi
  [[ "$actual" == "$expected" ]] || fail "Checksum mismatch for $name — refusing to install."
  ok "Checksum verified for $name"
}

# do_upgrade — pulls latest agentguard from git, then reinstalls all
# previously tracked agents.
do_upgrade() {
  section "agentguard upgrade"

  # Detect Homebrew-managed install: upgrade the package, then reinstall
  # tracked agents ourselves. Homebrew's post_install runs sandboxed on
  # macOS and cannot reliably write to $HOME, so we can't delegate this
  # to the formula — it must happen here, after the brew upgrade lands.
  # The ~/.local/bin wrapper runs from the opt symlink, so match that too.
  if [[ "$SCRIPT_DIR" == */Cellar/agentguard/* ]] || [[ "$SCRIPT_DIR" == */homebrew/*/agentguard/* ]] \
     || [[ "$SCRIPT_DIR" == */opt/agentguard/libexec ]]; then
    log "Homebrew install detected. Upgrading via brew..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would run: brew upgrade agentguard"
    else
      brew upgrade agentguard || fail "brew upgrade failed."
      ok "Homebrew package upgraded"
    fi

    local brew_prefix new_script_dir new_version tracked=""
    brew_prefix=$(brew --prefix agentguard 2>/dev/null) || fail "Could not resolve brew --prefix agentguard."
    new_script_dir="$brew_prefix/libexec"
    new_version=$(cat "$new_script_dir/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")

    if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
      tracked=$(grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
                | tail -n1 \
                | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//') || true
    fi
    if [[ -z "$tracked" ]]; then
      warn "No tracked agent installations found in $AGENTGUARD_CONFIG_FILE."
      exit 0
    fi
    echo ""
    log "Reinstalling tracked agents: $tracked"
    for agent in $tracked; do
      section "── $agent ──"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would uninstall $agent then reinstall $agent"
      else
        local skills
        skills=$(installed_skills "$agent")
        bash "$new_script_dir/install.sh" uninstall "$agent"
        echo ""
        AGENTGUARD_UPGRADE=1 bash "$new_script_dir/install.sh" "$agent" ${skills:+--skills "$skills"}
      fi
    done
    echo ""
    ok "Upgrade complete → agentguard v$new_version"
    return
  fi

  # Detect .deb install (Debian/Ubuntu) and self-update via GitHub releases.
  if [[ "$SCRIPT_DIR" == "/usr/lib/agentguard" ]]; then
    command -v dpkg >/dev/null 2>&1 || fail "Cannot upgrade: dpkg not found."
    log "Debian package install detected. Fetching latest release..."
    local deb_url deb_tmp sums_tmp
    deb_url=$(curl -fsSL "https://api.github.com/repos/SumonMSelim/agentguard/releases/latest" \
              | grep -Eo '"browser_download_url": *"[^"]+\.deb"' \
              | sed -E 's/.*"(https[^"]+)"/\1/') || fail "Could not resolve latest .deb release URL."
    [[ -n "$deb_url" ]] || fail "No .deb asset found in latest release."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would download and install: $deb_url"
    else
      deb_tmp="$(mktemp /tmp/agentguard-XXXXXX.deb)"
      sums_tmp="$(mktemp /tmp/agentguard-XXXXXX.sums)"
      curl -fsSL "$deb_url" -o "$deb_tmp" || fail "Download failed: $deb_url"
      curl -fsSL "${deb_url%/*}/SHA256SUMS" -o "$sums_tmp" \
        || fail "Download failed: ${deb_url%/*}/SHA256SUMS — refusing to install an unverified package."
      verify_sha256 "$deb_tmp" "$sums_tmp" "${deb_url##*/}"
      sudo dpkg -i "$deb_tmp" || fail "dpkg -i failed."
      rm -f "$deb_tmp" "$sums_tmp"
      ok "Debian package upgraded"
    fi

    local new_version tracked=""
    new_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
    if [[ -f "$AGENTGUARD_CONFIG_FILE" ]]; then
      tracked=$(grep -E '^AGENTGUARD_INSTALLED_AGENTS=' "$AGENTGUARD_CONFIG_FILE" \
                | tail -n1 \
                | sed -E 's/^AGENTGUARD_INSTALLED_AGENTS=//; s/^"//; s/"$//') || true
    fi
    if [[ -z "$tracked" ]]; then
      warn "No tracked agent installations found in $AGENTGUARD_CONFIG_FILE."
      exit 0
    fi
    echo ""
    log "Reinstalling tracked agents: $tracked"
    for agent in $tracked; do
      section "── $agent ──"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "Would uninstall $agent then reinstall $agent"
      else
        local skills
        skills=$(installed_skills "$agent")
        agentguard uninstall "$agent"
        echo ""
        AGENTGUARD_UPGRADE=1 agentguard "$agent" ${skills:+--skills "$skills"}
      fi
    done
    echo ""
    ok "Upgrade complete → agentguard v$new_version"
    return
  fi

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
    log "Run 'agentguard <agent>' (or './install.sh <agent>' for initial bootstrap) to install and start tracking."
    exit 0
  fi

  echo ""
  log "Reinstalling tracked agents: $tracked"
  for agent in $tracked; do
    section "── $agent ──"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would uninstall $agent then reinstall $agent"
    else
      local skills
      skills=$(installed_skills "$agent")
      bash "$SCRIPT_DIR/install.sh" uninstall "$agent"
      echo ""
      AGENTGUARD_UPGRADE=1 bash "$SCRIPT_DIR/install.sh" "$agent" ${skills:+--skills "$skills"}
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
#   - With an install record ($AGENTGUARD_CLAUDE_RECORD, see
#     record_claude_added): removes only the permission entries we added,
#     restores the previous attribution / includeGitInstructions values (or
#     deletes the key if there was none), and unsets defaultMode only if we
#     set it. The record is deleted afterwards.
#   - Without a record (installed by an older version): removes every entry
#     that matches our allow / ask / deny lists, deletes attribution,
#     includeGitInstructions and the legacy keys older versions set
#     (includeCoAuthoredBy, gitAttribution, disableGitWorkflow).
#   - Old per-tool block-env-read.sh matcher blocks are covered by the
#     command-string strip above.
#   - Empty allow / ask / deny arrays, an empty permissions object, empty
#     PreToolUse / PostToolUse arrays and an empty hooks object (unless the
#     user had one) are dropped.
#
# All other user keys are preserved untouched. Invalid JSON fails, unchanged.
unmerge_settings() {
  local settings="$1"
  local guardrails="$2"

  require jq

  if [[ ! -f "$settings" ]]; then
    log "settings.json not found — nothing to unmerge"
    [[ "$DRY_RUN" -eq 1 ]] || rm -f "$AGENTGUARD_CLAUDE_RECORD"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would unmerge agentguard entries from $settings"
    return
  fi

  if ! jq empty "$settings"; then
    fail "$settings is not valid JSON — fix it and re-run. File left unchanged."
  fi

  local guard_json rec_json='null'
  guard_json=$(cat "$guardrails")
  if [[ -f "$AGENTGUARD_CLAUDE_RECORD" ]] && jq empty "$AGENTGUARD_CLAUDE_RECORD" 2>/dev/null; then
    rec_json=$(cat "$AGENTGUARD_CLAUDE_RECORD")
  fi

  backup_if_exists "$settings"

  jq -n \
    --argjson current "$(cat "$settings")" \
    --argjson guard   "$guard_json" \
    --argjson rec     "$rec_json" \
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

    # The permission entries we own: the recorded additions when a record
    # exists, else everything in the guardrails config.
    def owned_perms(key):
      if $rec == null then $guard.permissions[key] // [] else $rec[key] // [] end;

    # Remove our entries from a permissions array.
    def strip_perms(key):
      if .permissions | has(key) then
        .permissions[key] |= map(select(. as $e | owned_perms(key) | index($e) == null))
      else . end;

    def drop_if_empty(path): if (getpath(path) | length) == 0 then delpaths([path]) else . end;

    # Restore a key we overwrote, unless the user changed it since install.
    def restore(k):
      if .[k] != $guard[k] then .
      elif $rec.scalars[k] == null then del(.[k])
      else .[k] = $rec.scalars[k] end;

    $current
    | if has("permissions") then
        strip_perms("allow") | strip_perms("ask") | strip_perms("deny")
      else . end
    # Without a record we cannot tell whether the user chose defaultMode, so
    # it is left alone.
    | if $rec.defaultMode == true
         and .permissions.defaultMode == ($guard.permissions.defaultMode // "acceptEdits")
      then del(.permissions.defaultMode) else . end
    | if has("permissions") then
        reduce ("allow", "ask", "deny") as $k (.;
          if .permissions | has($k) then drop_if_empty(["permissions", $k]) else . end)
        | drop_if_empty(["permissions"])
      else . end
    | if has("hooks") then
        .hooks.PreToolUse  = strip_hooks(.hooks.PreToolUse  // [])
        | .hooks.PostToolUse = strip_hooks(.hooks.PostToolUse // [])
        | drop_if_empty(["hooks", "PreToolUse"])
        | drop_if_empty(["hooks", "PostToolUse"])
        | if $rec.hadHooks == true then . else drop_if_empty(["hooks"]) end
      else . end
    | if $rec == null then
        del(.attribution, .includeGitInstructions,
            .includeCoAuthoredBy, .gitAttribution, .disableGitWorkflow)
      else
        restore("attribution") | restore("includeGitInstructions")
      end
    ' > "${settings}.tmp.$$" || {
      rm -f "${settings}.tmp.$$"
      fail "settings.json unmerge failed — $settings left unchanged."
    }
  mv "${settings}.tmp.$$" "$settings"
  rm -f "$AGENTGUARD_CLAUDE_RECORD"

  ok "settings.json unmerged → $settings"
}

uninstall_claude() {
  local dest="$HOME/.claude"

  section "Uninstalling Claude Code guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_instruction_file "$dest/CLAUDE.md" "$SCRIPT_DIR/agents/claude/CLAUDE.md"
  unmerge_settings "$dest/settings.json" "$SCRIPT_DIR/agents/claude/settings.json"
  untrack_installed_agent "claude"
}

uninstall_kiro() {
  local dest="$HOME/.kiro"

  section "Uninstalling Kiro guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  remove_instruction_file "$dest/KIRO.md" "$SCRIPT_DIR/agents/kiro/KIRO.md"
  remove_file  "$dest/agents/agentguard.json"
  untrack_installed_agent "kiro"
}

# unmerge_codex_hooks <file> — strips our entries from hooks.json; removes the
# file if nothing of the user is left in it.
unmerge_codex_hooks() {
  local f="$1" src="$SCRIPT_DIR/agents/codex/hooks.json"
  if [[ ! -f "$f" ]]; then
    log "$(basename "$f") not found (already removed?)"
    return
  fi
  local stripped
  stripped=$(jq --slurpfile g "$src" '
    [$g[0].hooks[][].hooks[].command] as $ours
    | .hooks |= ((. // {})
        | with_entries(.value |= (map(.hooks |= map(select(.command as $c | $ours | index($c) | not)))
                                  | map(select(.hooks | length > 0))))
        | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  ' "$f") || { warn "$f is not valid JSON — leaving in place"; return; }
  # Only our entries were in it: nothing of the user's to back up.
  if [[ "$stripped" == "{}" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "Would remove $f"
    else
      rm "$f"
      ok "Removed $f"
    fi
    return
  fi
  backup_if_exists "$f"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would strip agentguard hooks from $f"
  else
    echo "$stripped" > "$f"
    ok "agentguard hooks stripped from $f (user hooks kept)"
  fi
}

uninstall_codex() {
  local dest="$CODEX_DIR"

  section "Uninstalling Codex guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  remove_hooks "$dest/hooks"
  unmerge_codex_hooks "$dest/hooks.json"
  remove_instruction_file "$dest/AGENTS.md" "$SCRIPT_DIR/agents/codex/AGENTS.md"

  # Pre-#69 installs wrote ~/AGENTS.md. Clean it up unless grok still uses it.
  if [[ -f "$HOME/AGENTS.md" ]] && ! is_agent_tracked "grok"; then
    if codex_legacy_owned "$HOME/AGENTS.md"; then
      remove_file "$HOME/AGENTS.md"
    else
      remove_instruction_file "$HOME/AGENTS.md" "$SCRIPT_DIR/agents/codex/AGENTS.md"
    fi
  fi

  [[ "$DRY_RUN" -eq 0 ]] && { rmdir "$dest/hooks" 2>/dev/null || true; }
  untrack_installed_agent "codex"
}

# Relative to cursor_root. hooks.json is unmerged separately (it may hold user hooks).
CURSOR_AGENTGUARD_FILES=(
  ".cursor/hooks/_check-disabled.sh"
  ".cursor/hooks/audit-log.sh"
  ".cursor/hooks/block-destructive-ops.sh"
  ".cursor/hooks/block-env-read.sh"
  ".cursor/hooks/block-env.sh"
  ".cursor/hooks/block-main-branch.sh"
  ".cursor/hooks/block-self-edit.sh"
  ".cursor/hooks/block-system-installs.sh"
)

uninstall_cursor() {
  local dest
  dest="$(cursor_root)"
  local src_agents
  src_agents="$SCRIPT_DIR/agents/cursor/AGENTS.md"

  section "Uninstalling Cursor guardrails from $dest/.cursor"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  # Remove AGENTS.md only if agentguard owns it: the file must start with our
  # canonical header (skills may have been appended after, so exact match fails).
  # A --user install never writes AGENTS.md (and ~/AGENTS.md belongs to Grok).
  if [[ "$CURSOR_USER" -eq 0 && -f "$dest/AGENTS.md" && -f "$src_agents" ]]; then
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

  unmerge_cursor_hooks "$dest/.cursor/hooks.json"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    rmdir "$dest/.cursor/hooks" 2>/dev/null || true
    rmdir "$dest/.cursor" 2>/dev/null || true
  fi

  if [[ "$removed" -eq 0 ]]; then
    log "No Cursor guardrail files found (already removed?)"
  elif [[ "$DRY_RUN" -eq 0 ]]; then
    ok "Cursor guardrail files removed"
  fi
  [[ "$CURSOR_USER" -eq 1 ]] && untrack_installed_agent "cursor-user"
  return 0
}

uninstall_grok() {
  local dest="$HOME/.grok"

  section "Uninstalling Grok guardrails from $dest"
  [[ "$DRY_RUN" -eq 1 ]] && echo "  (dry-run: no files will be changed)"

  # Remove our hook scripts (shared names) and our registration json.
  remove_hooks "$dest/hooks"
  remove_file "$dest/hooks/agentguard.json"
  # ~/AGENTS.md is shared with codex — leave it while codex still uses it.
  if is_agent_tracked "codex"; then
    log "AGENTS.md still used by codex — leaving in place"
  else
    remove_instruction_file "$HOME/AGENTS.md" "$SCRIPT_DIR/agents/codex/AGENTS.md"
  fi

  # Clean empty hooks dir if possible (non-fatal).
  if [[ "$DRY_RUN" -eq 0 ]]; then
    rmdir "$dest/hooks" 2>/dev/null || true
    rmdir "$dest" 2>/dev/null || true
  fi

  untrack_installed_agent "grok"
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
    | map(select(.key | IN("attribution","includeGitInstructions")))
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
  local dest="$CODEX_DIR"
  section "Checking Codex installation → $dest"
  check_file "$dest/AGENTS.md" "AGENTS.md"
  for hook in "${AGENTGUARD_HOOKS[@]}"; do
    check_exec "$dest/hooks/$hook" "$hook"
  done
  check_file "$dest/hooks.json" "hooks.json"
  if [[ -f "$dest/hooks.json" ]]; then
    local missing
    missing=$(jq -r --slurpfile g "$SCRIPT_DIR/agents/codex/hooks.json" '
      [.hooks // {} | .[][]?.hooks[]?.command] as $have
      | [$g[0].hooks[][].hooks[].command] - $have | unique | .[]
    ' "$dest/hooks.json" 2>/dev/null) || missing="(hooks.json is not valid JSON)"
    if [[ -z "$missing" ]]; then
      _check_ok "hooks.json: all hook commands registered"
    else
      _check_fail "hooks.json: hook command(s) missing"
      printf '      missing: %s\n' "$missing"
    fi
  fi
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
  dest="$(cursor_root)/.cursor"
  section "Checking Cursor installation → $dest"
  [[ "$CURSOR_USER" -eq 0 ]] && check_file "$(pwd)/AGENTS.md" "AGENTS.md"
  for hook in "${AGENTGUARD_HOOKS[@]}"; do
    check_exec "$dest/hooks/$hook" "$hook"
  done
  check_file "$dest/hooks.json" "hooks.json"
  if [[ -f "$dest/hooks.json" ]]; then
    local missing
    # Per event, so an older hooks.json without the newer events is reported.
    missing=$(jq -r --argjson g "$(cursor_hooks_json)" '
      def pairs: to_entries[] | .key as $k | .value[]? | "\($k): \(.command)";
      [.hooks // {} | pairs] as $have
      | [$g.hooks | pairs] - $have | unique | .[]
    ' "$dest/hooks.json" 2>/dev/null) || missing="(hooks.json is not valid JSON)"
    if [[ -z "$missing" ]]; then
      _check_ok "hooks.json: all hook commands registered"
    else
      _check_fail "hooks.json: hook command(s) missing"
      printf '      missing: %s\n' "$missing"
    fi
  fi
  echo ""
}

check_grok() {
  local dest="$HOME/.grok"
  section "Checking Grok installation → $dest"
  check_file "$dest/hooks/agentguard.json" "agentguard.json (grok hooks)"
  check_exec "$dest/hooks/audit-log.sh" "audit-log.sh"
  check_exec "$dest/hooks/block-env-read.sh" "block-env-read.sh"
  check_file "$HOME/AGENTS.md" "AGENTS.md"
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
#   Grok:   AGENTS.md          (created if absent; Grok also supports .grok/ for project)

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
  log  "Install skills globally instead: agentguard kiro --skills <list> (or ./install.sh for bootstrap)" >&2
}

install_project_grok() {
  local file
  file="$(pwd)/AGENTS.md"

  section "Installing Grok project skills → $file"
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

# ── disable / enable / status ────────────────────────────────────────────────
#
# `agentguard disable [<dir>]` adds <dir> (or $PWD) to ~/.agentguard/disabled-dirs.
# Hooks check this file at runtime and exit 0 (allow) when the active directory
# matches an entry — making agentguard a no-op for that subtree.
#
# Disabling is gated to the user: the command refuses when CLAUDECODE=1 is set,
# requires a controlling terminal, and reads a typed confirmation from /dev/tty
# (not stdin), which no agent can supply. settings.json deny rules and
# block-self-edit.sh also block agents from invoking it via Bash. Enabling is
# open — restoring guardrails is never a risk.

AGENTGUARD_DISABLED_DIRS_FILE="${AGENTGUARD_DISABLED_DIRS_FILE:-$AGENTGUARD_CONFIG_DIR/disabled-dirs}"

_resolve_target_dir() {
  local raw="${TARGET_DIR:-}"
  if [[ -z "$raw" ]]; then
    raw="$(pwd -P)"
  elif [[ -d "$raw" ]]; then
    raw="$(cd "$raw" && pwd -P)"
  fi
  # Non-existent paths are allowed (enabling a since-deleted dir is reasonable).
  # Validate: absolute path, no embedded newlines, restricted charset to keep
  # the persisted file unambiguous to read back.
  if [[ "${raw:0:1}" != "/" ]]; then
    fail "Refusing non-absolute path: $raw"
  fi
  if [[ "$raw" == *$'\n'* ]]; then
    fail "Refusing path with embedded newline."
  fi
  printf '%s' "$raw"
}

cmd_disable() {
  if [[ "${CLAUDECODE:-}" == "1" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    fail "'agentguard disable' refuses to run inside a Claude Code session. Run it directly in your shell."
  fi
  local target
  target="$(_resolve_target_dir)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would disable agentguard in: $target"
    dry "Would write → $AGENTGUARD_DISABLED_DIRS_FILE"
    return
  fi

  # Confirmation is read from /dev/tty, never stdin, so `yes |` cannot answer it.
  if ! { : < /dev/tty > /dev/tty; } 2>/dev/null; then
    fail "'agentguard disable' needs an interactive terminal to confirm. Run it directly in your shell."
  fi
  local answer=""
  printf "  This turns OFF all agentguard guardrails in: %s\n  Type 'yes' to confirm: " "$target" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  if [[ "$answer" != "yes" ]]; then
    fail "Aborted. agentguard stays enabled in: $target"
  fi

  mkdir -p "$AGENTGUARD_CONFIG_DIR"
  touch "$AGENTGUARD_DISABLED_DIRS_FILE"
  if grep -qxF "$target" "$AGENTGUARD_DISABLED_DIRS_FILE" 2>/dev/null; then
    log "Already disabled: $target"
    return
  fi
  printf '%s\n' "$target" >> "$AGENTGUARD_DISABLED_DIRS_FILE"
  chmod 644 "$AGENTGUARD_DISABLED_DIRS_FILE"
  ok "agentguard DISABLED in: $target"
  log "Guardrails will not fire for this directory or any subdirectory."
  log "Re-enable with: agentguard enable"
}

cmd_enable() {
  local target
  target="$(_resolve_target_dir)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "Would enable agentguard in: $target"
    return
  fi

  if [[ ! -f "$AGENTGUARD_DISABLED_DIRS_FILE" ]]; then
    log "Nothing disabled — file does not exist."
    return
  fi
  if ! grep -qxF "$target" "$AGENTGUARD_DISABLED_DIRS_FILE" 2>/dev/null; then
    log "Not disabled: $target"
    return
  fi
  # grep -v exits 1 when no lines match (i.e. the file becomes empty), which
  # would short-circuit the chain and leave the original file untouched. Wrap
  # in a group with `|| true` so the empty-result case still produces a tmp.
  local tmp="$AGENTGUARD_DISABLED_DIRS_FILE.tmp"
  { grep -vxF "$target" "$AGENTGUARD_DISABLED_DIRS_FILE" || true; } > "$tmp"
  mv "$tmp" "$AGENTGUARD_DISABLED_DIRS_FILE"
  ok "agentguard ENABLED in: $target"
}

cmd_status() {
  local target
  target="$(_resolve_target_dir)"
  local hit=""
  if [[ -f "$AGENTGUARD_DISABLED_DIRS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
      if [[ "$target" == "$line" || "$target" == "$line"/* ]]; then
        hit="$line"
        break
      fi
    done < "$AGENTGUARD_DISABLED_DIRS_FILE"
  fi
  if [[ -n "$hit" ]]; then
    if [[ "$hit" == "$target" ]]; then
      printf "agentguard: DISABLED in %s\n" "$target"
    else
      printf "agentguard: DISABLED in %s (via ancestor %s)\n" "$target" "$hit"
    fi
  else
    printf "agentguard: enabled in %s\n" "$target"
  fi
}

# ── entry point ───────────────────────────────────────────────────────────────

if [[ "$DISABLE_CMD" -eq 1 ]]; then
  cmd_disable
  exit 0
fi

if [[ "$ENABLE_CMD" -eq 1 ]]; then
  cmd_enable
  exit 0
fi

if [[ "$STATUS_CMD" -eq 1 ]]; then
  cmd_status
  exit 0
fi

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
    grok)   check_grok   ;;
    all)    check_claude; check_codex; check_kiro; check_cursor; check_grok ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | grok | all" ;;
  esac
  if [[ "$_check_issues" -eq 0 ]]; then
    ok "All checks passed."
    check_for_update
    exit 0
  else
    warn "$_check_issues issue(s) found. Run 'agentguard [agent]' to fix."
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
    grok)   uninstall_grok   ;;
    all)    uninstall_claude; echo; uninstall_codex; echo; uninstall_kiro; echo; uninstall_cursor; echo; uninstall_grok; echo; remove_agentguard_config; remove_file "$HOME/.local/bin/agentguard" ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | grok | all" ;;
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
    grok)   install_project_grok   ;;
    all)    install_project_claude; echo; install_project_codex; echo; install_project_kiro; echo; install_project_grok ;;
    *)      fail "Unknown agent '$AGENT'. Valid options: claude | codex | cursor | kiro | grok | all" ;;
  esac
  echo ""
  ok "Done."
  [[ "$DRY_RUN" -eq 1 ]] && dry "no files were written"
  exit 0
fi

# Reject unknown agents before any interactive prompt.
case "$AGENT" in
  claude|codex|kiro|cursor|grok|all) ;;
  *) fail "Unknown agent '$AGENT'. Valid options: claude | codex | kiro | cursor | grok | all" ;;
esac

# do_upgrade re-execs child installs with AGENTGUARD_UPGRADE=1, which makes
# prompt_protected_branches keep the saved value instead of prompting.
[[ "$UPGRADE" -eq 0 ]] && prompt_protected_branches

case "$AGENT" in
  claude) install_claude ;;
  codex)  install_codex  ;;
  kiro)   install_kiro   ;;
  cursor) install_cursor ;;
  grok)   install_grok   ;;
  all)    install_claude; echo; install_codex; echo; install_kiro; echo; install_cursor; echo; install_grok ;;
esac

install_cli_wrapper

echo ""
ok "Done."
[[ "$DRY_RUN" -eq 1 ]] && dry "no files were written"
[[ "$AGENT" == "kiro" || "$AGENT" == "all" ]] && [[ "$DRY_RUN" -eq 0 ]] && \
  log "Switch to the 'agentguard' agent in Kiro to activate guardrails."
exit 0
