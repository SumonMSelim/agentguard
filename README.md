# agentguard

[![Shell: bash](https://img.shields.io/badge/shell-bash-green.svg)](hooks/)
[![CI](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Universal security guardrails and workflow policies for AI coding agents.

- Hooks are written in bash and are tool-agnostic.
- Agent-specific config lives under `agents/`.
- A single `install.sh` deploys everything to the right location for each tool.

## Supported agents

| Agent                                                               | Config location | Enforcement layers                          |
|---------------------------------------------------------------------|-----------------|---------------------------------------------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/hooks) | `~/.claude/`    | settings.json + shell hooks + CLAUDE.md     |
| [OpenAI Codex](https://github.com/openai/codex)                     | `~/AGENTS.md`   | Instruction file only (hooks not supported) |
| [Kiro](https://kiro.dev/docs/cli/hooks/)                            | `~/.kiro/`      | shell hooks + agent config + KIRO.md        |

## Structure

```
agents/
├── claude/
│   ├── settings.json         # Claude Code permissions, hooks config, attribution
│   └── CLAUDE.md             # Behavioural instructions loaded every session
├── codex/
│   └── AGENTS.md             # Codex instruction file (mirrors CLAUDE.md policies)
└── kiro/
    ├── agent.json            # Kiro agent config with hooks wired up
    └── KIRO.md               # Behavioural instructions loaded every session

hooks/                        # Shared bash hooks — tool-agnostic, used by Claude and Kiro
├── block-env.sh              # Blocks .env access, bare env dumps, gh auth token (best-effort, see Notes)
├── block-env-read.sh         # Blocks .env, key files, and credentials via Read/Write/Edit/fs_read/fs_write tools (primary)
├── block-main-branch.sh      # Blocks commits/pushes on main/master; all force-push forms
├── block-system-installs.sh  # Blocks system package manager calls
├── block-destructive-ops.sh  # Blocks rm on root/home; pipe-to-shell patterns
└── audit-log.sh              # PostToolUse: appends every tool call to the agent's audit.log

skills/                       # Optional behavioural skill packs — deployed alongside instruction files
└── karpathy-guidelines/
    └── SKILL.md              # Karpathy's 4 coding guidelines (think, simplify, surgical, goal-driven)

install.sh                    # Installer: ./install.sh [claude|codex|kiro|all]
README.md
```

## What's enforced

| Rule                                                                          | Mechanism                                                                            |
|-------------------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| Never read `.env`, key files, or credentials                                  | `deny` rules (Claude) + `block-env.sh` (best-effort) + `block-env-read.sh` (primary) |
| `.envrc`, `*.pem`, `*.key`, `*.p12`, `~/.netrc` blocked                       | `block-env-read.sh` hook                                                             |
| Bare `env` dump blocked; `env VAR=val cmd` allowed                            | `block-env.sh` hook (targets dump patterns only)                                     |
| `gh auth token` blocked                                                       | `block-env.sh` hook                                                                  |
| Read tools auto-approved globally                                             | `allow` rules in `settings.json` (Claude only)                                       |
| Ask before commit / push / PR                                                 | `ask` rules (Claude) + instruction file (all agents)                                 |
| Ask before destructive git ops                                                | `ask` rules (Claude): `reset --hard`, `clean -f`, `branch -D`, `stash drop/clear`    |
| Never commit/push from main/master                                            | `block-main-branch.sh` hook (inspects git state at runtime)                          |
| Force push always blocked (all forms incl. `--force-with-lease`)              | `deny` rules (Claude) + `block-main-branch.sh` hook                                  |
| Pipe-to-shell blocked (`curl\|bash`, `wget\|sh`, etc.)                        | `block-destructive-ops.sh` hook                                                      |
| Catastrophic `rm` blocked (`/`, `~`, `$HOME`) — not project paths (see Notes) | `block-destructive-ops.sh` hook                                                      |
| Always use Docker to run code                                                 | Instruction file + `block-system-installs.sh` hook                                   |
| Never install system packages                                                 | `block-system-installs.sh` hook                                                      |
| Conventional Commits on all messages                                          | Instruction file                                                                     |
| No AI attribution in commits                                                  | `includeCoAuthoredBy`/`gitAttribution` settings (Claude) + instruction file          |
| No over-engineering, ask before big changes                                   | Instruction file                                                                     |
| Audit log of every tool call                                                  | `audit-log.sh` PostToolUse hook → `~/.claude/audit.log` or `~/.kiro/audit.log`       |

## Installation

Requires: `bash`, `jq`.

```bash
# Claude Code
./install.sh claude

# Codex
./install.sh codex

# Kiro
./install.sh kiro

# All
./install.sh all
```

Re-running is safe. Existing files are backed up with a timestamp suffix before any write.
`settings.json` is **merged**, not overwritten — see [Merge behavior](#merge-behavior-settingsjson).

Verify after installing Claude:

```bash
claude --print-config
```

## Merge behavior (settings.json)

When an existing `~/.claude/settings.json` is found, `install.sh` merges rather than replaces:

- **`permissions.allow` / `ask` / `deny`** — Union: guardrail entries are added to your existing list, deduplicated.
- **`hooks.PreToolUse` / `hooks.PostToolUse`** — Merge by matcher: for each matcher, guardrail hooks are appended and deduplicated by command string. New matchers are added as whole blocks.
- **`includeCoAuthoredBy`**, **`gitAttribution`**, **`disableGitWorkflow`** — Guardrails always win; these are security-critical.
- **`permissions.defaultMode`** — Guardrails set this to `acceptEdits`, which auto-approves file reads/writes without prompting. This is a usability tradeoff: it keeps the agent flowing without constant interruptions, while the hooks and deny rules handle the actual security boundaries. If you prefer the agent to ask before every file change, set `"defaultMode": "ask"` in your local `~/.claude/settings.json` after installing — the merge logic will preserve your value on re-runs.
- **Everything else** (`env`, `model`, `apiKey`, Bedrock config, etc.) — Your values are preserved untouched.

## Skills

Skills are optional behavioural packs appended to the agent's instruction file at install time. Each skill lives in `skills/<name>/SKILL.md` with a YAML front-matter block.

| Skill | Tags | What it does |
|-------|------|-------------|
| [`karpathy-guidelines`](skills/karpathy-guidelines/SKILL.md) | `core` | 4 coding guidelines from Andrej Karpathy: think before coding, simplicity first, surgical changes, goal-driven execution |

Skills tagged `core` are appended automatically. Language- or project-specific skills are opt-in via `--skills`.

```bash
# Default: appends all core-tagged skills
./install.sh claude

# Explicit list: append only the named skills
./install.sh claude --skills karpathy-guidelines,clean-code-python

# Skip all skills
./install.sh claude --skills none
```

Skills are appended to the instruction file the agent reads (`CLAUDE.md`, `KIRO.md`, `AGENTS.md`). The YAML front-matter is stripped — only the content is appended.

### Adding a skill

1. Create `skills/<name>/SKILL.md` with YAML front-matter (`name`, `tags`, `description`, `license`) followed by the skill content.
2. Tag it `core` to include it by default, or leave it untagged for opt-in only.
3. `install.sh` picks it up automatically — no other changes needed.

---

## Adding a new agent

1. Create `agents/<name>/` with the tool's instruction file (e.g. `RULES.md`, `AGENTS.md` — whatever the tool reads) and, if the tool supports hooks, a config file wiring them up (e.g. `agent.json` for Kiro, `settings.json` for Claude).
2. Add an `install_<name>()` function to `install.sh` that copies the instruction file, hooks config, and shared hooks to the right location.
3. Add the agent to the `case` block in `install.sh` and to the table above.

## Notes

- Hooks are the reliable enforcement layer for Claude Code. Declarative `deny` rules in `settings.json` have known pattern-matching limitations, so hooks provide the belt-and-suspenders backstop.

- `block-main-branch.sh` only protects `main` and `master`. For projects using a different protected branch (e.g. `develop`, `trunk`), Claude users can add a project-level `.claude/settings.json` pointing to a custom hook; Kiro users can create a project-level agent config.

- `pip install` without `sudo` outside a virtualenv is not blocked at the hook level (too many false positives). The instruction file covers it.

- `block-env.sh` is best-effort. It intercepts common viewer/editor patterns (`cat`, `less`, `vim`, etc.) but cannot enumerate every possible Bash reader (`awk`, `strings`, `python3 -c`, etc.). `block-env-read.sh` is the primary enforcement layer for `.env` reads — it intercepts the Read/Write/Edit tools (Claude) and fs_read/fs_write tools (Kiro), which is how agents access files in normal operation.

- `block-destructive-ops.sh` only blocks `rm` targeting `/`, `~`, and `$HOME`. Project-level `rm -rf ./src` is intentionally not blocked — legitimate uses like `rm -rf node_modules` or `rm -rf dist` are too common. If your project requires stricter protection, add a project-level `.claude/settings.json` with a custom hook that checks for paths specific to your codebase.

- `disableGitWorkflow: true` disables Claude Code's built-in automatic git workflow. All git behaviour is owned by the hooks and CLAUDE.md instead.

- `audit-log.sh` writes to `~/.claude/audit.log` (Claude) or `~/.kiro/audit.log` (Kiro) with no rotation. On a busy machine this file will grow unbounded. To cap it, add a `logrotate` config:

  ```
  # /etc/logrotate.d/claude-audit  (or ~/.config/logrotate/claude-audit)
  /Users/<you>/.claude/audit.log {
      weekly
      rotate 4
      compress
      missingok
      notifempty
  }
  ```

  Adjust the path to `~/.kiro/audit.log` for Kiro.

- Codex does not support shell hooks. All enforcement for Codex is instruction-only — there is no automated backstop.

- Kiro hooks run via the `agentguard` agent config (`~/.kiro/agents/agentguard.json`). Switch to the `agentguard` agent in Kiro to activate guardrails. The hooks use Kiro's native `preToolUse`/`postToolUse` system with the same exit-code-2 blocking semantics as Claude Code.

## Disclaimer

Always review before running these on your system. While these are tested, use them at your own risk.

## License

[MIT License](LICENSE) - feel free to use and modify as needed.

---

**Tip:** Star this repo!
