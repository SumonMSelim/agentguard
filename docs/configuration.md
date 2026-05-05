# Configuration

## Protect additional branches

By default only `main` and `master` are protected from direct commits and pushes. To extend:

```bash
export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop,trunk"
```

Set this in your shell profile, or in a project-level `.claude/settings.json` hook env block (Claude), or your Kiro agent config / shell profile (Kiro).

## settings.json merge rules (Claude)

When an existing `~/.claude/settings.json` is found, `install.sh` merges rather than replaces:

| Key | Behavior |
|-----|----------|
| `permissions.allow/ask/deny` | Union of your entries + agentguard entries, deduplicated |
| `hooks.PreToolUse/PostToolUse` | Merged by matcher; your existing hooks preserved |
| `includeCoAuthoredBy`, `gitAttribution`, `disableGitWorkflow` | agentguard always wins — security-critical |
| Everything else (`model`, `apiKey`, `env`, etc.) | Your values preserved untouched |

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

```
/Users/<you>/.claude/audit.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

## Skills

Skills are behavioural packs appended to the instruction file at install time.

```bash
./install.sh claude                              # append all core-tagged skills (default)
./install.sh claude --skills karpathy-guidelines # append specific skills only
./install.sh claude --skills none                # skip all skills
```

To add a skill: create `skills/<name>/SKILL.md` with YAML front-matter (`name`, `tags`, `description`, `license`) followed by the content. Tag it `core` to include by default. `install.sh` picks it up automatically.

## Upgrade

Re-running `install.sh` will not overwrite existing instruction files — it only appends missing skills. To pick up changes from a new agentguard version:

```bash
./install.sh uninstall claude
./install.sh claude
```
