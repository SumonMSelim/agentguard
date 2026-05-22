# Configuration

## What's enforced

| Rule                                                         | How                                                            |
|--------------------------------------------------------------|----------------------------------------------------------------|
| `.env`, key files, credentials never read                    | `block-env-read.sh` (primary) + `block-env.sh` (bash surface)  |
| Force push always blocked                                    | `deny` rules + `block-main-branch.sh`                          |
| No commits/pushes directly to main/master                    | `block-main-branch.sh`                                         |
| Ask before `git commit`, `push`, `reset --hard`, `branch -D` | `ask` rules (Claude) + instruction file                        |
| System package managers blocked (`brew`, `apt`, `yum`, etc.) | `block-system-installs.sh`                                     |
| `pip install` outside a virtualenv blocked                   | `block-system-installs.sh` (checks `VIRTUAL_ENV`)              |
| `rm /`, `rm ~`, `rm $HOME` blocked                           | `block-destructive-ops.sh`                                     |
| Pipe-to-shell blocked (`curl \| bash`, `wget \| sh`)         | `block-destructive-ops.sh`                                     |
| `gh auth token` blocked                                      | `block-env.sh`                                                 |
| No AI attribution in commits                                 | `gitAttribution` / `includeCoAuthoredBy` settings              |
| Conventional Commits, no over-engineering                    | Instruction file                                               |
| Every tool call logged                                       | `audit-log.sh` → `~/.claude/audit.log` / `~/.kiro/audit.log` / `.cursor/audit.log` |

## Protect additional branches

By default only `main` and `master` are protected from direct commits and pushes. To extend:

```bash
export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop,trunk"
```

Set this in your shell profile, or in a project-level `.claude/settings.json` hook env block (Claude), or your Kiro agent config / shell profile (Kiro).

## settings.json merge rules (Claude)

When an existing `~/.claude/settings.json` is found, `install.sh` merges rather than replaces:

| Key                                                           | Behavior                                                 |
|---------------------------------------------------------------|----------------------------------------------------------|
| `permissions.allow/ask/deny`                                  | Union of your entries + agentguard entries, deduplicated |
| `hooks.PreToolUse/PostToolUse`                                | Merged by matcher; your existing hooks preserved         |
| `includeCoAuthoredBy`, `gitAttribution`, `disableGitWorkflow` | agentguard always wins — security-critical               |
| Everything else (`model`, `apiKey`, `env`, etc.)              | Your values preserved untouched                          |

## defaultMode

Installed as `acceptEdits`, which auto-approves file reads/writes without prompting. This keeps the agent flowing; hooks and deny rules handle the security boundaries.

To review every file change instead:

```json
// ~/.claude/settings.json
{ "permissions": { "defaultMode": "ask" } }
```

The merge logic will preserve this value on re-runs.

## Audit log rotation

`audit-log.sh` appends to `~/.claude/audit.log` (or `~/.kiro/audit.log`) with no rotation. To cap growth, add a `logrotate` config:

```conf
/Users/<you>/.claude/audit.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

For Cursor, the audit log is project-local: `.cursor/audit.log`.

## Skills

Skills are behavioural packs appended to the instruction file at install time.

```bash
./install.sh claude                              # append all core-tagged skills (default)
./install.sh claude --skills karpathy-guidelines # append specific skills only
./install.sh claude --skills none                # skip all skills
```

### Per-project skills

`--project` targets the instruction file in the current directory instead of `~`. Hooks and `settings.json` are not touched.

```bash
# From your project root:
./install.sh claude --project --skills go,aws    # → .claude/CLAUDE.md
./install.sh codex  --project --skills go,aws    # → AGENTS.md
./install.sh cursor --project --skills go,aws    # → AGENTS.md (skills only, no hooks)
./install.sh cursor --skills go,aws              # → AGENTS.md + hooks (full install)
./install.sh kiro   --project --skills go,aws    # prints warning — not supported
```

Kiro's `agent.json` hardcodes a single global file path; per-project overrides require manual `agent.json` edits.

### Adding a skill

Create `skills/<name>/SKILL.md` with YAML front-matter (`name`, `tags`, `description`, `license`) followed by the content. Tag it `core` to include by default. `install.sh` picks it up automatically.

## Upgrade

Re-running `install.sh` will not overwrite existing instruction files — it only appends missing skills. To pick up changes from a new agentguard version:

```bash
./install.sh uninstall claude
./install.sh claude
```
