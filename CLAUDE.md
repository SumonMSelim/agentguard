# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

agentguard installs security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex). It enforces rules at the shell hook level — not just as instructions. The install target is the user's home directory (`~/.claude/`, `~/.kiro/`) or current project directory (`.cursor/`), not this repo itself.

## Commands

```bash
# Install
./install.sh claude                          # Claude Code (global)
./install.sh kiro                            # Kiro (global)
./install.sh cursor                          # Cursor (project-local, runs from CWD)
./install.sh all                             # All agents
./install.sh claude --dry-run                # Preview without writing
./install.sh claude --skills go,aws          # With specific skill packs
./install.sh cursor --skills go,aws          # Cursor full install + skills
./install.sh claude --project --skills go    # Append skills to CWD only (no hooks)
./install.sh cursor --project --skills go    # Cursor skills-only (no hooks)

# Uninstall
./install.sh uninstall claude
./install.sh uninstall claude --dry-run

# Check installation health (exits 1 if anything missing)
./install.sh check claude
./install.sh check all

# Tests
bash tests/run_all.sh                        # All suites
bash tests/claude.sh                         # Hook logic + Claude install check
bash tests/claude.sh hooks                   # Hook logic only
bash tests/claude.sh install                 # Install check only
bash tests/check-sync.sh                     # Assert instruction files are in sync
```

Requirements: `bash`, `jq`.

## Architecture

### Hooks (`hooks/`)
Six shell scripts enforcing rules at the tool-call level. Each reads JSON from stdin and exits `2` to block or `0` to allow. Hook exit codes: `0` = allow, `2` = block (agent sees stderr as feedback), `1` = hook error (also blocks).

| Hook | What it blocks |
|------|---------------|
| `block-env.sh` | `cat .env`, `printenv`, `env`, `gh auth token` (bash surface) |
| `block-env-read.sh` | Read/Write/Edit on `.env*`, `.pem`, `.key`, `credentials`, `~/.aws/`, `~/.ssh/` |
| `block-main-branch.sh` | `git push` to `main`/`master`, force push, `git commit` on protected branch. Respects `AGENTGUARD_PROTECTED_BRANCHES` env var |
| `block-system-installs.sh` | `brew`, `apt`, `yum`, `npm -g`, `yarn global`, `pip install` outside virtualenv (checks `$VIRTUAL_ENV`) |
| `block-destructive-ops.sh` | `rm -rf /`, `rm ~`, pipe-to-shell (`curl \| bash`, `wget \| sh`) |
| `audit-log.sh` | Logs every tool call (PostToolUse) — writes to `dirname($0)/../audit.log` |

Hooks handle two payload shapes:
- Claude/Kiro: `{ "tool_input": { "command": "..." } }` (nested)
- Cursor: `{ "command": "..." }` (flat, top-level)

All command-reading hooks use `.command // .tool_input.command` to handle both.

### Agents (`agents/`)
Per-agent config installed to the agent's home directory:
- `agents/claude/` → `~/.claude/` (CLAUDE.md + settings.json)
- `agents/kiro/` → `~/.kiro/` (KIRO.md + agent.json for `agentguard` agent)
- `agents/codex/` → `~/AGENTS.md` (instruction-only, no hook support)
- `agents/cursor/` → `<CWD>/.cursor/` (hooks.json + hooks/ copied from `hooks/`)

**Instruction file sync rule**: `agents/claude/CLAUDE.md` is the canonical source. `agents/kiro/KIRO.md` and `agents/cursor/AGENTS.md` must be byte-for-byte identical to it. `agents/codex/AGENTS.md` must match modulo its 3-line Codex header (lines 3-5). `tests/check-sync.sh` enforces all four.

### Settings merge (`install.sh: merge_settings`)
When `~/.claude/settings.json` already exists, the installer merges rather than overwrites:
- `permissions.allow/ask/deny` → union + deduplicate
- `hooks.PreToolUse/PostToolUse` → merge by matcher key, append hooks (dedup by command string)
- `permissions.defaultMode` → user value wins
- `includeCoAuthoredBy`, `gitAttribution`, `disableGitWorkflow` → guardrails value always wins

Uninstall uses `unmerge_settings` to surgically strip only agentguard entries.

### Skills (`skills/`)
Markdown files appended to the instruction file at install time. Each `SKILL.md` has YAML frontmatter with `name`, `tags`, `description`, `license`. Skills tagged `core` (`karpathy-guidelines`, `docker`) are auto-included. Others require `--skills <name>`.

Duplication is prevented by a sentinel comment: `<!-- agentguard:skill:<name> -->`.

### Tests (`tests/`)
- `claude.sh` / `kiro.sh` — pipe JSON payloads to hooks and assert exit codes. `check()` for path-independent tests, `check_in()` for tests that need a specific git branch (creates temp repos).
- `check-sync.sh` — diffs instruction files.
- `uninstall.sh` — installs then uninstalls, verifies clean state.
- `check.sh` — exercises `./install.sh check`.
- `project.sh` — exercises `--project` flag installs.
- `run_all.sh` — runs all suites, exits 1 if any fail.

## Key constraints

- `block-env-read.sh` is the primary `.env` guard (intercepts Read/Write/Edit tools). `block-env.sh` is best-effort on bash surface only.
- Kiro guardrails only activate under the `agentguard` agent — user must switch to it after install.
- Cursor install is always project-local (CWD). Run `./install.sh cursor` from the target project root.
- Upgrade path: uninstall then reinstall. Re-running install skips existing files.
- When adding a new hook, add it to `AGENTGUARD_HOOKS` array in `install.sh` and `CURSOR_AGENTGUARD_FILES` for Cursor uninstall tracking.
