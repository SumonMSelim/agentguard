# agentguard

[![CI](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Security guardrails and workflow policies for AI coding agents. Blocks dangerous operations at the hook level — not just as instructions.

## Supported agents

| Agent                                                               | Enforcement                                         |
|---------------------------------------------------------------------|-----------------------------------------------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/hooks) | Shell hooks + settings.json + instruction file      |
| [Kiro](https://kiro.dev/docs/cli/hooks/)                            | Shell hooks + agent config + instruction file       |
| [Cursor](https://cursor.com)                                        | Project-level hooks + rules/skills (via `.cursor/`) |
| [OpenAI Codex](https://github.com/openai/codex)                     | Instruction file only (no hook support)             |

See [docs/configuration.md](docs/configuration.md) for the full list of enforced rules.

## Installation

Requires: `bash`, `jq`.

```bash
# Clone once, install globally
git clone https://github.com/SumonMSelim/agentguard.git ~/agentguard
~/agentguard/install.sh claude   # Claude Code (installs to ~/.claude/)
~/agentguard/install.sh kiro     # Kiro (installs to ~/.kiro/)
~/agentguard/install.sh cursor   # Cursor IDE (installs to .cursor/ in current directory)
~/agentguard/install.sh codex    # Codex (installs to ~/AGENTS.md)
~/agentguard/install.sh all      # All agents
```

Installing Claude Code guardrails also drops an `agentguard` CLI wrapper to `~/.local/bin/`. After that you can run `agentguard` from any directory:

```bash
agentguard claude --project --skills go,aws   # add skills to current project
agentguard check claude                        # verify installation
agentguard uninstall claude                    # remove
```

If `~/.local/bin` is not in your `PATH`, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
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
agentguard uninstall claude
agentguard uninstall all
agentguard uninstall claude --dry-run   # preview first
```

Removes only what agentguard owns: hooks, instruction file, Kiro agent config, CLI wrapper. Claude `settings.json` is surgically unmerged — your own keys untouched, file not deleted.

## Check installation status

```bash
agentguard check claude
agentguard check all
```

Reports which hooks, files, settings, and CLI wrapper are present or missing. Exits 1 if anything is out of order — useful in CI to assert guardrails are in place.

## Upgrade

Re-running install skips existing files — it only appends missing skills. To pick up a new agentguard version:

```bash
cd ~/agentguard && git pull
agentguard uninstall claude
agentguard claude
```

## Skills

Skills are behavioural packs appended to the agent's instruction file at install time. `core` skills are included automatically; all others are opt-in via `--skills`.

| Skill                                                        | Tags   | What it does                                                                   |
|--------------------------------------------------------------|--------|--------------------------------------------------------------------------------|
| [`karpathy-guidelines`](skills/karpathy-guidelines/SKILL.md) | `core` | Think before coding, simplicity first, surgical changes, goal-driven execution |
| [`docker`](skills/docker/SKILL.md)                           | —      | Image security, build efficiency, runtime hardening                            |
| [`go`](skills/go/SKILL.md)                                   | —      | Idiomatic Go: errors, interfaces, concurrency, testing, security               |
| [`php`](skills/php/SKILL.md)                                 | —      | Modern PHP: strict types, security, PSR standards, architecture                |
| [`laravel`](skills/laravel/SKILL.md)                         | —      | Laravel: thin controllers, Eloquent, queues, security                          |
| [`java`](skills/java/SKILL.md)                               | —      | Modern Java (17+): design, immutability, security, testing                     |
| [`aws`](skills/aws/SKILL.md)                                 | —      | AWS: IAM least privilege, secrets, networking, security posture                |
| [`gcp`](skills/gcp/SKILL.md)                                 | —      | GCP: IAM, Workload Identity, Security Command Center                           |
| [`kubernetes`](skills/kubernetes/SKILL.md)                   | —      | K8s: pod security, RBAC, resource limits, HA                                   |
| [`terraform`](skills/terraform/SKILL.md)                     | —      | Terraform: state management, security, module design, workflow                 |

### Global skills

Install once, active in every project. Best for universal practices that apply regardless of stack.

```bash
# Core skills only (default)
agentguard claude

# Add language/cloud skills globally
agentguard claude --skills go,aws,kubernetes

# Skip all skills
agentguard claude --skills none
```

### Per-project skills

`--project` appends skills to the instruction file in the **current directory** instead of `~`. No hooks or settings changes — skills only. Requires `agentguard` CLI (installed with Claude Code global install).

| Agent       | File written                                          | Notes                            |
|-------------|-------------------------------------------------------|----------------------------------|
| Claude Code | `.claude/CLAUDE.md` in CWD                            |                                  |
| Codex       | `AGENTS.md` in CWD                                    |                                  |
| Cursor      | `.cursor/` in CWD (hooks + `AGENTS.md`)               | Always project-local; full install |
| Kiro        | —                                                     | Not supported; prints warning    |

```bash
# All agents at once — recommended:
agentguard all --project --skills go,aws

# Or per-agent:
agentguard claude --project --skills go,aws     # → .claude/CLAUDE.md
agentguard codex  --project --skills go,aws     # → AGENTS.md
agentguard cursor --skills go,aws               # → .cursor/ (hooks + AGENTS.md)

# Preview without writing:
agentguard all --project --skills go,aws --dry-run
```

Claude Code loads both `~/.claude/CLAUDE.md` (global) and `.claude/CLAUDE.md` (project) simultaneously — project skills layer on top. Codex checks `AGENTS.md` in CWD first, then `~/AGENTS.md`. Cursor reads only the project-local `AGENTS.md`.

**Recommended pattern:** install `core` skills globally (guardrails apply everywhere), add language and cloud skills per project where relevant.

### Adding a skill

Create `skills/<name>/SKILL.md` with YAML frontmatter (`name`, `tags`, `description`, `license`) followed by markdown content. Tag `core` to auto-include on every install. `install.sh` picks it up automatically — no registration needed.

## Notes

- **Kiro** — guardrails only activate when using the `agentguard` agent. Switch to it in Kiro after install.
- **Cursor** — guardrails are project-local. `agentguard cursor` installs `.cursor/` into the current directory.
- **Codex** — instruction-only; no hooks, no automated enforcement backstop.
- **`block-env.sh`** — best-effort on the bash surface. `block-env-read.sh` is the primary layer (intercepts Read/Write/Edit tools directly).

→ [Configuration reference](docs/configuration.md) — protected branches, settings.json merge rules, audit log rotation.

## License

[MIT](LICENSE)
