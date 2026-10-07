# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repo.

## What this repo is

agentguard installs security guardrails for AI coding agents (Claude Code, Kiro, Cursor, Codex, Grok, Gemini CLI, GitHub Copilot CLI, Windsurf, Google Antigravity CLI). Enforces rules at shell hook level — not just instructions. Install target: user home (`~/.claude/`, `~/.kiro/`, `~/.codex/`, `~/.grok/`, `~/.gemini/`, `~/.copilot/`, `~/.codeium/windsurf/`, `~/.gemini/config/`) or project dir (`.cursor/`), not this repo.

## Commands

**Preferred:** Use the `agentguard` command (installed by the wrapper or packages).

```bash
# Install / manage guardrails
agentguard claude                          # Claude Code (global)
agentguard kiro                            # Kiro (global)
agentguard codex                           # Codex (global, ~/.codex)
agentguard grok                            # Grok
agentguard gemini                          # Gemini CLI (global, ~/.gemini)
agentguard copilot                         # GitHub Copilot CLI (global, ~/.copilot)
agentguard windsurf                        # Windsurf Cascade (global, ~/.codeium/windsurf)
agentguard antigravity                     # Google Antigravity CLI (global, ~/.gemini/config + ~/.gemini/AGENTS.md)
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

# Audit log (reads audit.log.1 + audit.log; default agent all, --tail 50)
agentguard log
agentguard log claude --blocked --since 2h --tail 20

# Bootstrap (one time only, from a fresh clone — this installs the `agentguard` CLI wrapper)
#   ./install.sh claude     # after this, use `agentguard claude` etc. for everything

# Tests
bash tests/run_all.sh                        # All suites
bash tests/claude.sh                         # Hook logic + Claude install check
bash tests/claude.sh hooks                   # Hook logic only
bash tests/claude.sh install                 # Install check only
bash tests/check-sync.sh                     # Assert instruction files are in sync
bash tests/install.sh                        # Install / merge edge cases
bash tests/bypass.sh                         # Bypass regression suite
```

Requirements: `bash`, `jq`.

## Architecture

### Hooks (`hooks/`)
Seven shell scripts enforcing rules at tool-call level, plus `_check-disabled.sh`, the shared library every hook sources right after reading stdin into `INPUT` (never registered on its own). It resolves `jq` (fail closed without it), skips all checks when the payload's `cwd` is listed in `~/.agentguard/disabled-dirs`, and defines the shared helpers: `_agentguard_command` (command from any payload shape), `_agentguard_invalid_payload`, `_is_cursor`, `_is_copilot`, `_is_antigravity`, `_allow` (exit 0, Cursor allow JSON), `_grok_block` (stderr + `BLOCKED` audit line + Cursor/Copilot/Grok deny JSON + exit 2; Antigravity deny JSON + exit 0), `_agentguard_log_block` and the audit-log path, redaction and rotation. Hooks hold only their own checks. Each reads JSON from stdin, exits `2` to block or `0` to allow. Exit codes: `0` = allow, `2` = block (agent sees stderr as feedback), `1` = hook error, which Claude Code treats as non-blocking (stderr shown, action proceeds); hooks therefore exit `2` on internal errors such as missing `jq` or an unparseable payload.

| Hook | What it blocks |
|------|---------------|
| `block-env.sh` | `cat .env` (any case), reads of `~/.ssh/*`, `~/.aws/*` and similar credential stores, `printenv`, `env`, `gh auth token` (bash surface) |
| `block-env-read.sh` | Read/Write/Edit on `.env*` (any case; not `.env.example` etc.), private keys, `credentials`, `~/.aws/`, `~/.ssh/`, tool and agent credential stores |
| `block-main-branch.sh` | `git push` to `main`/`master`, force push (incl. `+refspec`, `--mirror`, `--all`), `git commit`/`merge`/`rebase`/`cherry-pick`/`revert`/`am` on protected branch. Respects `AGENTGUARD_PROTECTED_BRANCHES` env var |
| `block-system-installs.sh` | `brew`, `apt`, `yum`, `npm -g`, `yarn global`, `pip install` outside virtualenv (checks `$VIRTUAL_ENV`) |
| `block-destructive-ops.sh` | `rm` on `/`, `~` or `$HOME`; recursive `rm` of `.`, `..`, `.git`, `*` or a system dir; `find / -delete`; recursive `chmod`/`chown` on root or home; `mkfs`/`dd`/raw disk writes; overwriting `/etc/passwd` and similar; fork bomb; pipe-to-shell (`curl \| bash`, `wget \| sh`, `bash <(curl ...)`) |
| `block-self-edit.sh` | Bash writes to agentguard's own config (agent settings, hooks, instruction files, `~/.agentguard`, audit logs) and `agentguard disable` / `install.sh disable` |
| `audit-log.sh` | Logs every tool call (PostToolUse) — writes to `dirname($0)/../audit.log`. Block paths in every hook add a `BLOCKED hook=<name>` line via `_agentguard_log_block` (`_check-disabled.sh`). Secrets redacted, mode 600, rotated to `audit.log.1` above 1 MB. `AGENTGUARD_AUDIT_LOG` overrides the path (tests) |

Hooks handle four payload shapes:
- Claude/Kiro/Codex/Gemini: `{ "tool_input": { "command": "..." } }` (nested). Gemini CLI (`BeforeTool`/`AfterTool`) blocks on exit 2 with stderr as the reason and needs no stdout, so it takes the Claude path
- Grok: `{ "toolInput": { "command": "..." } }` (nested, camelCase)
- Cursor: `{ "command": "..." }` (flat, top-level) for `beforeShellExecution`/`beforeReadFile`; `preToolUse` and `beforeMCPExecution` carry `tool_name`/`tool_input` and are told apart by `hook_event_name` (`beforeMCPExecution` `tool_input` is a JSON string)
- Copilot CLI: `{ "toolName": "bash", "toolArgs": "{\"command\":\"...\"}", "cwd": "..." }` (camelCase `preToolUse`/`postToolUse`; `toolArgs` a JSON string or object, raw text for `apply_patch`). `_check-disabled.sh` maps it to `tool_name`/`tool_input` on load (raw text → `tool_input.command`), so hooks read it like Claude; `_is_copilot` (`has("toolArgs")`) makes `_grok_block` print `{"permissionDecision":"deny","permissionDecisionReason":...}`. Allow prints nothing
- Windsurf: `{ "agent_action_name": "pre_run_command", "tool_info": { "command_line": "...", "cwd": "..." } }`; `pre_read_code`/`pre_write_code` carry `tool_info.file_path`, `pre_mcp_tool_use` `tool_info.mcp_tool_arguments`. Exit 2 blocks with stderr shown to the agent, any other non-zero exit lets the action proceed, no stdout needed: Claude path
- Antigravity CLI: `{ "toolCall": { "name": "run_command", "args": { "CommandLine": "...", "Cwd": "..." } }, "workspacePaths": [...], "stepIdx": 0, ... }` (no `cwd`, no event name). `_check-disabled.sh` maps it on load: `tool_name` = `toolCall.name`, `tool_input` = `args` plus `command` (`CommandLine`), `file_path` (`TargetFile`/`AbsolutePath`), `path` (`DirectoryPath`/`SearchDirectory`/`SearchPath`), `cwd` = `args.Cwd` or `workspacePaths[0]`. `_is_antigravity` (`has("toolCall")`) makes `_grok_block` print `{"decision":"deny","reason":...}` and exit 0 (the docs give only the JSON channel; users report any non-zero exit also denies). Allow prints nothing: `{"decision":"allow"}` would skip the user's own permission prompt

All command-reading hooks use `_agentguard_command` (`.command // .tool_input.command // .toolInput.command // .tool_info.command_line`). User-level Cursor hooks run from `~/.cursor`; `_check-disabled.sh` moves to `$CURSOR_PROJECT_DIR` so branch and disabled-dir checks see the project.

### Agents (`agents/`)
Per-agent config installed to agent's home dir:
- `agents/claude/` → `~/.claude/` (CLAUDE.md + settings.json)
- `agents/kiro/` → `~/.kiro/` (KIRO.md + agent.json for `agentguard` agent, used by Kiro CLI 2.x + hooks.json → `~/.kiro/hooks/agentguard.json`, the v1 standalone hook format used by Kiro CLI 3.x with `shell`/`read`/`write` matchers; shell hooks are also registered under `execute_bash` because Kiro may report either name)
- `agents/codex/` → `~/.codex/` (AGENTS.md + hooks.json merged with any user hooks; hooks/ copied from `hooks/`). A legacy agentguard-created `~/AGENTS.md` is migrated unless grok is installed
- `agents/cursor/` → `<CWD>/.cursor/`, or `~/.cursor/` with `--user` (hooks.json merged with any user hooks, ours refreshed on re-run; hooks/ copied from `hooks/`). `--user` writes no AGENTS.md and is tracked as `cursor-user` for upgrade
- `agents/grok/` → `~/.grok/hooks/` (hooks.json installed as `agentguard.json` + hooks copied from `hooks/`); instructions go to `~/AGENTS.md`, copied from `agents/codex/AGENTS.md`
- `agents/gemini/` → `~/.gemini/` (GEMINI.md + hooks.json, whose `hooks` key is merged into `~/.gemini/settings.json` by `merge_hooks_json`, the same helper Codex uses: user keys and hooks kept, dedup by command, invalid JSON refused; uninstall `unmerge_hooks_json` strips only our commands; hooks/ copied from `hooks/`). Only hook entries are added, no settings scalars, so there is no ownership record. `check gemini` also fails when `hooksConfig.enabled` is `false`
- `agents/copilot/` → `~/.copilot/` (copilot-instructions.md + hooks.json installed as `~/.copilot/hooks/agentguard.json`, our own file since Copilot runs every `*.json` in that dir; hooks/ copied from `hooks/`, `.sh` files are not read as config). `check copilot` fails when `agentguard.json` differs from `agents/copilot/hooks.json`. Project: `.github/copilot-instructions.md`. `COPILOT_HOME` is not followed (install warns)
- `agents/windsurf/` → `~/.codeium/windsurf/` (hooks.json merged into the user `hooks.json` by `merge_cursor_hooks`/`unmerge_cursor_hooks` with Windsurf's entries passed in: same flat `{"hooks":{"<event>":[{"command":..}]}}` shape, no `version`; hooks/ copied from `hooks/`; `global_rules.md` → `memories/global_rules.md`). Windsurf caps global rules at 6,000 characters, so `append_skills` takes a byte limit and skips skills that would pass it. `--project` writes the root `AGENTS.md` (always-on workspace rule)
- `agents/antigravity/` → `~/.gemini/config/` (hooks.json, whose top-level `agentguard` entry is set into the user `~/.gemini/config/hooks.json` by `merge_named_hooks`: named entries `{"<name>":{"PreToolUse":[{"matcher":..,"hooks":[..]}]}}`, other entries kept, ours replaced on re-run so a user `"enabled": false` on it is reset, invalid JSON or a non-object refused, `mv_keep_mode`; `unmerge_named_hooks` deletes only our entry and the file if nothing else is left; hooks/ copied from `hooks/`) + `AGENTS.md` → `~/.gemini/AGENTS.md` (24,000-byte limit passed to `append_skills`). That hooks.json is shared with the Antigravity app and IDE. Gemini CLI's files (`~/.gemini/settings.json`, `GEMINI.md`, `hooks/`) are not touched, so both install side by side. `check antigravity` fails when our entry differs from `agents/antigravity/hooks.json` (incl. `"enabled": false`). `--project` writes the root `AGENTS.md`

**Instruction file sync rule**: `agents/claude/CLAUDE.md` is canonical source. `agents/kiro/KIRO.md`, `agents/codex/AGENTS.md`, `agents/cursor/AGENTS.md`, `agents/gemini/GEMINI.md`, `agents/copilot/copilot-instructions.md`, `agents/windsurf/global_rules.md` and `agents/antigravity/AGENTS.md` must be byte-for-byte identical (`AGENTS.md` is in `.gitignore`: `git add -f`). `tests/check-sync.sh` enforces all eight and that the Windsurf copy stays under 5,900 bytes.

### Agent registry and hook list (`install.sh`)
- `AGENTS=(claude codex kiro cursor grok gemini copilot windsurf antigravity)` is the single agent list. It drives agent validation (the "Valid options" error), `all` for install / check / uninstall / `--project`, and dispatch by naming convention: each agent has `install_<agent>`, `uninstall_<agent>`, `check_<agent>` and `install_project_<agent>`. Agent-specific bodies stay in those functions.
- `AGENTGUARD_HOOKS` is generated from `hooks/*.sh` at startup. Install copies, `check_*` verifies (all hooks for every agent), uninstall removes (incl. Cursor) from that one list. The release workflow globs `hooks/*.sh` too.

### Settings merge (`install.sh`: merge_settings)
When `~/.claude/settings.json` exists, installer merges rather than overwrites:
- `permissions.allow/ask/deny` → union + deduplicate, user order kept (known-stale entries pruned first)
- `hooks.PreToolUse/PostToolUse` → merge by matcher key, append hooks (dedup by command string); old per-tool `block-env-read.sh` blocks (`Read`, `Write`, `Edit`, `MultiEdit`) are replaced by `Read|Write|Edit|Grep|Glob|NotebookEdit`
- File mode kept: every tmp+mv rewrite of a user file (settings.json, Codex/Cursor/Windsurf/Antigravity hooks.json, Gemini settings.json, instruction files) goes through `mv_keep_mode`, so a 600 file stays 600
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
- `log.sh` — exercises `agentguard log` against fake audit logs (filters, prefixing, BSD `date` fallback, missing-log exit code).
- `project.sh` — exercises `--project` flag installs.
- `upgrade.sh` — version tracking, `upgrade` (from a throwaway clone), checksum verify.
- `install.sh` — install edge cases: `claude` then `all`, re-install idempotency, odd settings.json shapes, invalid JSON refused, HOME with a space, Cursor hooks.json, full round trip.
- `bypass.sh` — bypass regression suite: known bypass forms through the whole Bash hook chain (Claude, Cursor, Gemini CLI, Copilot CLI, Windsurf and Antigravity payload shapes) stay blocked, everyday commands stay allowed.
- `run_all.sh` — runs all suites, exits 1 if any fail.

CI (`.github/workflows/test.yml`) runs `run_all.sh` on ubuntu and macOS (BSD tools) plus a `shellcheck -S warning` job.

## Key constraints

- `block-env-read.sh` is primary `.env` guard (intercepts Read/Write/Edit tools). `block-env.sh` is best-effort on bash surface only.
- Kiro CLI 2.x guardrails only activate under `agentguard` agent — user must switch after install. Kiro CLI 3.x global hooks (`~/.kiro/hooks/agentguard.json`) apply to all agents. Keep `agents/kiro/agent.json` and `agents/kiro/hooks.json` wiring the same hook commands (`tests/kiro.sh` checks this).
- Codex hooks run only after the user trusts them with `/hooks` in Codex. Codex `apply_patch` payloads carry patch text in `tool_input.command`, not a file path, so `block-env-read.sh` is not registered for it; only `block-self-edit.sh` is.
- Cursor (and Grok project) installs are project-local (CWD) unless `agentguard cursor --user`. Run `agentguard cursor` from the target project root (after the CLI wrapper is installed). For the initial bootstrap you may run the `install.sh` script directly.
- Upgrade path: use `agentguard upgrade` (or uninstall then reinstall). Re-running skips existing files.
- Adding new hook: drop it in `hooks/` (install, check, uninstall and release pick it up from `hooks/*.sh`). Start it with `INPUT=$(cat)`, source `_check-disabled.sh`, parse with `_agentguard_command` (or validate JSON and call `_agentguard_invalid_payload`), block with `_grok_block "<msg>"` and end with `_allow`. Register it per agent: `agents/claude/settings.json`, `agents/kiro/agent.json` + `hooks.json`, `agents/codex/hooks.json`, `agents/grok/hooks.json`, `agents/gemini/hooks.json`, `agents/copilot/hooks.json` (flat `preToolUse` entries with `matcher` + `bash`), `agents/windsurf/hooks.json`, `agents/antigravity/hooks.json`, and `agents/cursor/hooks.json` with project-relative `.cursor/hooks/` paths (`--user` rewrites them to absolute `~/.cursor/hooks/`).
- Adding new agent: add its name to `AGENTS` in `install.sh`, then write `install_<agent>`, `uninstall_<agent>`, `check_<agent>` and `install_project_<agent>` (plus an `installed_skills` case if upgrade should keep its skills).