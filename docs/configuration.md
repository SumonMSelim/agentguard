# Configuration

## What's enforced

| Rule                                                         | How                                                                                |
|--------------------------------------------------------------|------------------------------------------------------------------------------------|
| `.env`, key files, credentials never read                    | `block-env-read.sh` (primary) + `block-env.sh` (bash surface)                      |
| Force push always blocked                                    | `deny` rules + `block-main-branch.sh`                                              |
| No commits/pushes directly to main/master                    | `block-main-branch.sh`                                                             |
| Ask before `git commit`, `push`, `reset --hard`, `branch -D` | `ask` rules (Claude) + instruction file                                            |
| System package managers blocked (`brew`, `apt`, `yum`, etc.) | `block-system-installs.sh`                                                         |
| `pip install` outside a virtualenv blocked                   | `block-system-installs.sh` (checks `VIRTUAL_ENV`)                                  |
| `rm /`, `rm ~`, `rm $HOME` blocked                           | `block-destructive-ops.sh`                                                         |
| Pipe-to-shell blocked (`curl \| bash`, `wget \| sh`)         | `block-destructive-ops.sh`                                                         |
| `gh auth token` blocked                                      | `block-env.sh`                                                                     |
| No AI attribution in commits                                 | `gitAttribution` / `includeCoAuthoredBy` settings                                  |
| Conventional Commits, no over-engineering                    | Instruction file                                                                   |
| Every tool call logged                                       | `audit-log.sh` → `~/.claude/audit.log` / `~/.kiro/audit.log` / `.cursor/audit.log` |

## Protect additional branches

By default only `main` and `master` are protected from direct commits and pushes. To extend:

```bash
export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop,trunk"
```

Set this in your shell profile, a project-level `.claude/settings.json` hook env block (Claude), or your Kiro agent config / shell profile (Kiro).

## settings.json merge rules (Claude)

When an existing `~/.claude/settings.json` is found, `install.sh` merges rather than replaces:

| Key                                                           | Behavior                                                 |
|---------------------------------------------------------------|----------------------------------------------------------|
| `permissions.allow/ask/deny`                                  | Union of your entries + agentguard entries, deduplicated |
| `hooks.PreToolUse/PostToolUse`                                | Merged by matcher; your existing hooks preserved         |
| `includeCoAuthoredBy`, `gitAttribution`, `disableGitWorkflow` | agentguard always wins — security-critical               |
| Everything else (`model`, `apiKey`, `env`, etc.)              | Your values preserved untouched                          |

## defaultMode

Installed as `acceptEdits`, which auto-approves file reads/writes without prompting. Hooks and deny rules handle the security boundaries.

To review every file change instead:

```json
// ~/.claude/settings.json
{ "permissions": { "defaultMode": "ask" } }
```

This value is preserved on re-runs.

## Audit log rotation

`audit-log.sh` appends one line per tool call with no rotation. Log paths:

- Claude: `~/.claude/audit.log`
- Kiro: `~/.kiro/audit.log`
- Cursor: `.cursor/audit.log` (project-local)

To cap growth, add a `logrotate` config:

```conf
/Users/<you>/.claude/audit.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```
