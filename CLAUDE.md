# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repo.

## What this repo is

agentguard installs security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex, Grok). Enforces rules at shell hook level — not just instructions. Install target: user home (`~/.claude/`, `~/.kiro/`, `~/.codex/`, `~/.grok/`) or project dir (`.cursor/`), not this repo.

## Commands

**Preferred:** Use the `agentguard` command (installed by the wrapper or packages).

```bash
# Install / manage guardrails
agentguard claude                          # Claude Code (global)
agentguard kiro                            # Kiro (global)
agentguard codex                           # Codex (global, ~/.codex)
agentguard grok                            # Grok
agentguard cursor                          # Cursor (project-local, run from CWD)
agentguard cursor --user                   # Cursor user-level hooks (~/.cursor, all projects)
agentguard all                             # All agents
agentguard claude --dry-run                # Preview without writing
agentguard claude --skills go,aws          # With specific skill packs
agentguard cursor --skills go,aws          # Cursor full install + skills
agentguard claude --project --skills go    # Append skills to CWD only (no hooks)

# Uninstall / check
agentguard uninstall claude
agentguard uninstall claude --dry-run
agentguard check claude
agentguard check all

# Bootstrap (one time only, from a fresh clone — this installs the `agentguard` CLI wrapper)
#   ./install.sh claude     # after this, use `agentguard claude` etc. for everything

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
Seven shell scripts enforcing rules at tool-call level, plus `_check-disabled.sh`, a helper every hook sources (never registered on its own): it skips all checks when the payload's `cwd` is listed in `~/.agentguard/disabled-dirs`, and provides `_agentguard_log_block` and the audit-log path, redaction and rotation. Each reads JSON from stdin, exits `2` to block or `0` to allow. Exit codes: `0` = allow, `2` = block (agent sees stderr as feedback), `1` = hook error, which Claude Code treats as non-blocking (stderr shown, action proceeds); hooks therefore exit `2` on internal errors such as missing `jq` or an unparseable payload.

| Hook | What it blocks |
|------|---------------|
| `block-env.sh` | `cat .env`, `printenv`, `env`, `gh auth token` (bash surface) |
| `block-env-read.sh` | Read/Write/Edit on `.env*` (not `.env.example` etc.), private keys, `credentials`, `~/.aws/`, `~/.ssh/`, tool and agent credential stores |
| `block-main-branch.sh` | `git push` to `main`/`master`, force push (incl. `+refspec`, `--mirror`, `--all`), `git commit`/`merge`/`rebase`/`cherry-pick`/`revert`/`am` on protected branch. Respects `AGENTGUARD_PROTECTED_BRANCHES` env var |
| `block-system-installs.sh` | `brew`, `apt`, `yum`, `npm -g`, `yarn global`, `pip install` outside virtualenv (checks `$VIRTUAL_ENV`) |
| `block-destructive-ops.sh` | `rm` on `/`, `~` or `$HOME`; recursive `rm` of `.`, `..`, `.git`, `*` or a system dir; `find / -delete`; recursive `chmod`/`chown` on root or home; `mkfs`/`dd`/raw disk writes; overwriting `/etc/passwd` and similar; fork bomb; pipe-to-shell (`curl \| bash`, `wget \| sh`, `bash <(curl ...)`) |
| `block-self-edit.sh` | Bash writes to agentguard's own config (agent settings, hooks, instruction files, `~/.agentguard`, audit logs) and `agentguard disable` / `install.sh disable` |
| `audit-log.sh` | Logs every tool call (PostToolUse) — writes to `dirname($0)/../audit.log`. Block paths in every hook add a `BLOCKED hook=<name>` line via `_agentguard_log_block` (`_check-disabled.sh`). Secrets redacted, mode 600, rotated to `audit.log.1` above 1 MB. `AGENTGUARD_AUDIT_LOG` overrides the path (tests) |

Hooks handle three payload shapes:
- Claude/Kiro/Codex: `{ "tool_input": { "command": "..." } }` (nested)
- Grok: `{ "toolInput": { "command": "..." } }` (nested, camelCase)
- Cursor: `{ "command": "..." }` (flat, top-level) for `beforeShellExecution`/`beforeReadFile`; `preToolUse` and `beforeMCPExecution` carry `tool_name`/`tool_input` and are told apart by `hook_event_name` (`beforeMCPExecution` `tool_input` is a JSON string)

All command-reading hooks use `.command // .tool_input.command // .toolInput.command`. User-level Cursor hooks run from `~/.cursor`; `_check-disabled.sh` moves to `$CURSOR_PROJECT_DIR` so branch and disabled-dir checks see the project.

### Agents (`agents/`)
Per-agent config installed to agent's home dir:
- `agents/claude/` → `~/.claude/` (CLAUDE.md + settings.json)
- `agents/kiro/` → `~/.kiro/` (KIRO.md + agent.json for `agentguard` agent, used by Kiro CLI 2.x + hooks.json → `~/.kiro/hooks/agentguard.json`, the v1 standalone hook format used by Kiro CLI 3.x with `shell`/`read`/`write` matchers; shell hooks are also registered under `execute_bash` because Kiro may report either name)
- `agents/codex/` → `~/.codex/` (AGENTS.md + hooks.json merged with any user hooks; hooks/ copied from `hooks/`). A legacy agentguard-created `~/AGENTS.md` is migrated unless grok is installed
- `agents/cursor/` → `<CWD>/.cursor/`, or `~/.cursor/` with `--user` (hooks.json merged with any user hooks, ours refreshed on re-run; hooks/ copied from `hooks/`). `--user` writes no AGENTS.md and is tracked as `cursor-user` for upgrade
- `agents/grok/` → `~/.grok/hooks/` (hooks.json installed as `agentguard.json` + hooks copied from `hooks/`); instructions go to `~/AGENTS.md`, copied from `agents/codex/AGENTS.md`

**Instruction file sync rule**: `agents/claude/CLAUDE.md` is canonical source. `agents/kiro/KIRO.md`, `agents/codex/AGENTS.md` and `agents/cursor/AGENTS.md` must be byte-for-byte identical. `tests/check-sync.sh` enforces all four.

### Settings merge (`install.sh`: merge_settings)
When `~/.claude/settings.json` exists, installer merges rather than overwrites:
- `permissions.allow/ask/deny` → union + deduplicate, user order kept (known-stale entries pruned first)
- `hooks.PreToolUse/PostToolUse` → merge by matcher key, append hooks (dedup by command string); old per-tool `block-env-read.sh` blocks (`Read`, `Write`, `Edit`, `MultiEdit`) are replaced by `Read|Write|Edit|Grep|Glob|NotebookEdit`
- `permissions.defaultMode` → user value wins
- `attribution`, `includeGitInstructions` → guardrails value always wins. Legacy `includeCoAuthoredBy`, `gitAttribution`, `disableGitWorkflow` are removed when they still hold our old value

Install first writes `~/.agentguard/claude-added.json` (`record_claude_added`): the permission entries it adds, whether it set `defaultMode`, the previous `attribution`/`includeGitInstructions` values, and whether the user had `hooks`. Uninstall uses `unmerge_settings` to remove only those entries, restore those values, and drop empty containers; without a record (older install) it strips every matching entry and leaves `defaultMode` alone.

### Skills (`skills/`)
Markdown files appended to instruction file at install. Each `SKILL.md` has YAML frontmatter: `name`, `tags`, `description`, `license`. Skills tagged `core` (currently only `karpathy-guidelines`) are included when `--skills` is omitted. An explicit `--skills` list installs only the named skills; `--skills none` installs none.

Duplication prevented by sentinel comment: `<!-- agentguard:skill:<name> -->`.

### Tests (`tests/`)
- `claude.sh` / `kiro.sh` — pipe JSON payloads to hooks, assert exit codes. `check()` for path-independent tests, `check_in()` for tests needing specific git branch (creates temp repos).
- `check-sync.sh` — diffs instruction files.
- `uninstall.sh` — installs then uninstalls, verifies clean state.
- `check.sh` — exercises `agentguard check` (or direct script during development).
- `project.sh` — exercises `--project` flag installs.
- `upgrade.sh` — version check, agent tracking and `agentguard upgrade`.
- `run_all.sh` — runs all suites, exits 1 if any fail.

## Key constraints

- `block-env-read.sh` is primary `.env` guard (intercepts Read/Write/Edit tools). `block-env.sh` is best-effort on bash surface only.
- Kiro CLI 2.x guardrails only activate under `agentguard` agent — user must switch after install. Kiro CLI 3.x global hooks (`~/.kiro/hooks/agentguard.json`) apply to all agents. Keep `agents/kiro/agent.json` and `agents/kiro/hooks.json` wiring the same hook commands (`tests/kiro.sh` checks this).
- Codex hooks run only after the user trusts them with `/hooks` in Codex. Codex `apply_patch` payloads carry patch text in `tool_input.command`, not a file path, so `block-env-read.sh` is not registered for it; only `block-self-edit.sh` is.
- Cursor (and Grok project) installs are project-local (CWD) unless `agentguard cursor --user`. Run `agentguard cursor` from the target project root (after the CLI wrapper is installed). For the initial bootstrap you may run the `install.sh` script directly.
- Upgrade path: use `agentguard upgrade` (or uninstall then reinstall). Re-running skips existing files.
- Adding new hook: add to `AGENTGUARD_HOOKS` array in `install.sh` and `CURSOR_AGENTGUARD_FILES` for Cursor uninstall tracking. Register it in `agents/cursor/hooks.json` with project-relative `.cursor/hooks/` paths (`--user` rewrites them to absolute `~/.cursor/hooks/`).