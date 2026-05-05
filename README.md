# agentguard

[![CI](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Security guardrails and workflow policies for AI coding agents. Blocks dangerous operations at the hook level — not just as instructions.

## Supported agents

| Agent | Enforcement |
|-------|-------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/hooks) | Shell hooks + settings.json + instruction file |
| [Kiro](https://kiro.dev/docs/cli/hooks/) | Shell hooks + agent config + instruction file |
| [OpenAI Codex](https://github.com/openai/codex) | Instruction file only (no hook support) |

## What's enforced

| Rule | How |
|------|-----|
| `.env`, key files, credentials never read | `block-env-read.sh` (primary) + `block-env.sh` (bash surface) |
| Force push always blocked | `deny` rules + `block-main-branch.sh` |
| No commits/pushes directly to main/master | `block-main-branch.sh` |
| Ask before `git commit`, `push`, `reset --hard`, `branch -D` | `ask` rules (Claude) + instruction file |
| System package managers blocked (`brew`, `apt`, `yum`, etc.) | `block-system-installs.sh` |
| `pip install` outside a virtualenv blocked | `block-system-installs.sh` (checks `VIRTUAL_ENV`) |
| `rm /`, `rm ~`, `rm $HOME` blocked | `block-destructive-ops.sh` |
| Pipe-to-shell blocked (`curl \| bash`, `wget \| sh`) | `block-destructive-ops.sh` |
| `gh auth token` blocked | `block-env.sh` |
| No AI attribution in commits | `gitAttribution` / `includeCoAuthoredBy` settings |
| Conventional Commits, no over-engineering | Instruction file |
| Every tool call logged | `audit-log.sh` → `~/.claude/audit.log` / `~/.kiro/audit.log` |

## Installation

Requires: `bash`, `jq`.

```bash
./install.sh claude   # Claude Code
./install.sh kiro     # Kiro
./install.sh codex    # Codex
./install.sh all      # All agents
```

```bash
--dry-run                              # preview changes without writing anything
--skills none                          # skip skill packs
--skills karpathy-guidelines,other     # append specific skills only
```

Re-running is safe — existing files are backed up with a timestamp suffix. `settings.json` is merged, not overwritten.

## Uninstall

```bash
./install.sh uninstall claude
./install.sh uninstall all
./install.sh uninstall claude --dry-run   # preview first
```

Removes only what agentguard owns: hooks, instruction file, Kiro agent config. Claude `settings.json` is surgically unmerged — your own keys untouched, file not deleted.

## Check installation status

```bash
./install.sh check claude
./install.sh check all
```

Reports which hooks, files, and settings are present or missing. Exits 1 if anything is out of order — useful in CI to assert guardrails are in place.

## Skills

| Skill | What it does |
|-------|-------------|
| [`karpathy-guidelines`](skills/karpathy-guidelines/SKILL.md) | Think before coding, simplicity first, surgical changes, goal-driven execution |

`core` skills are appended automatically. See [docs/configuration.md](docs/configuration.md) to add skills or change selection.

## Notes

- **Kiro** — guardrails only activate when using the `agentguard` agent. Switch to it in Kiro after install.
- **Codex** — instruction-only; no hooks, no automated enforcement backstop.
- **`block-env.sh`** — best-effort on the bash surface. `block-env-read.sh` is the primary layer (intercepts Read/Write/Edit tools directly).
- **Upgrade** — re-running install won't overwrite existing files. To pick up a new version: uninstall then install.

→ [Configuration reference](docs/configuration.md) — protected branches, settings.json merge rules, audit log rotation, skills.

## License

[MIT](LICENSE)
