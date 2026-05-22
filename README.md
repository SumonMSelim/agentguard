# agentguard

[![CI](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Security guardrails and workflow policies for AI coding agents. Blocks dangerous operations at the hook level — not just as instructions.

## Supported agents

| Agent                                                               | Enforcement                                    |
|---------------------------------------------------------------------|------------------------------------------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/hooks) | Shell hooks + settings.json + instruction file |
| [Kiro](https://kiro.dev/docs/cli/hooks/)                            | Shell hooks + agent config + instruction file  |
| [OpenAI Codex](https://github.com/openai/codex)                     | Instruction file only (no hook support)        |

## What's enforced

| Rule                                                         | How                                                           |
|--------------------------------------------------------------|---------------------------------------------------------------|
| `.env`, key files, credentials never read                    | `block-env-read.sh` (primary) + `block-env.sh` (bash surface) |
| Force push always blocked                                    | `deny` rules + `block-main-branch.sh`                         |
| No commits/pushes directly to main/master                    | `block-main-branch.sh`                                        |
| Ask before `git commit`, `push`, `reset --hard`, `branch -D` | `ask` rules (Claude) + instruction file                       |
| System package managers blocked (`brew`, `apt`, `yum`, etc.) | `block-system-installs.sh`                                    |
| `pip install` outside a virtualenv blocked                   | `block-system-installs.sh` (checks `VIRTUAL_ENV`)             |
| `rm /`, `rm ~`, `rm $HOME` blocked                           | `block-destructive-ops.sh`                                    |
| Pipe-to-shell blocked (`curl \| bash`, `wget \| sh`)         | `block-destructive-ops.sh`                                    |
| `gh auth token` blocked                                      | `block-env.sh`                                                |
| No AI attribution in commits                                 | `gitAttribution` / `includeCoAuthoredBy` settings             |
| Conventional Commits, no over-engineering                    | Instruction file                                              |
| Every tool call logged                                       | `audit-log.sh` → `~/.claude/audit.log` / `~/.kiro/audit.log`  |

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
--project                              # install to current project directory (skills only)
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

Skills are behavioural packs appended to the agent's instruction file. `core` skills are included automatically on every install; all others are opt-in.

| Skill                                                        | Tags   | What it does                                                                   |
|--------------------------------------------------------------|--------|--------------------------------------------------------------------------------|
| [`karpathy-guidelines`](skills/karpathy-guidelines/SKILL.md) | `core` | Think before coding, simplicity first, surgical changes, goal-driven execution |
| [`docker`](skills/docker/SKILL.md)                           | `core` | Image security, build efficiency, runtime hardening                            |
| [`go`](skills/go/SKILL.md)                                   | —      | Idiomatic Go: errors, interfaces, concurrency, testing, security               |
| [`php`](skills/php/SKILL.md)                                 | —      | Modern PHP: strict types, security, PSR standards, architecture                |
| [`laravel`](skills/laravel/SKILL.md)                         | —      | Laravel: thin controllers, Eloquent, queues, security                          |
| [`java`](skills/java/SKILL.md)                               | —      | Modern Java (17+): design, immutability, security, testing                     |
| [`aws`](skills/aws/SKILL.md)                                 | —      | AWS: IAM least privilege, secrets, networking, security posture                |
| [`gcp`](skills/gcp/SKILL.md)                                 | —      | GCP: IAM, Workload Identity, Security Command Center                           |
| [`kubernetes`](skills/kubernetes/SKILL.md)                   | —      | K8s: pod security, RBAC, resource limits, HA                                   |
| [`terraform`](skills/terraform/SKILL.md)                     | —      | Terraform: state management, security, module design, workflow                 |

### Global skills

Install once, active in every project. Best for universal practices and skills that apply regardless of stack.

```bash
# Core skills only (default)
./install.sh claude

# Add language/cloud skills globally
./install.sh claude --skills go,aws,kubernetes

# All skills
./install.sh claude --skills go,php,laravel,java,aws,gcp,kubernetes,terraform,docker
```

### Per-project skills

`--project` appends skills to the instruction file in the **current directory** instead of `~`. No hooks or settings changes — skills only.

| Agent | File written |
|-------|-------------|
| Claude Code | `.claude/CLAUDE.md` in CWD |
| Codex | `AGENTS.md` in CWD |
| Kiro | Not supported — install globally |

```bash
# In your Go + AWS project root:
cd ~/projects/my-service
./install.sh claude --project --skills go,aws

# Codex in the same project:
./install.sh codex --project --skills go,aws

# Preview without writing:
./install.sh claude --project --skills go,aws --dry-run
```

Claude Code loads both `~/.claude/CLAUDE.md` (global) and `.claude/CLAUDE.md` (project) simultaneously — project skills layer on top. Codex checks `AGENTS.md` in CWD first, then `~/AGENTS.md`.

**Recommended pattern:** install `core` skills globally (guardrails + docker apply everywhere), add language and cloud skills per project where they're relevant.

See [docs/configuration.md](docs/configuration.md) for full skills documentation.

## Notes

- **Kiro** — guardrails only activate when using the `agentguard` agent. Switch to it in Kiro after install.
- **Codex** — instruction-only; no hooks, no automated enforcement backstop.
- **`block-env.sh`** — best-effort on the bash surface. `block-env-read.sh` is the primary layer (intercepts Read/Write/Edit tools directly).
- **Upgrade** — re-running install won't overwrite existing files. To pick up a new version: uninstall then install.

→ [Configuration reference](docs/configuration.md) — protected branches, settings.json merge rules, audit log rotation, skills.

## License

[MIT](LICENSE)
