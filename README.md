# agentguard

[![CI](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/test.yml)
[![Release](https://github.com/SumonMSelim/agentguard/actions/workflows/release.yml/badge.svg)](https://github.com/SumonMSelim/agentguard/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/SumonMSelim/agentguard)](https://github.com/SumonMSelim/agentguard/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS | Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey.svg)](#installation)
[![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25.svg?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Requires jq](https://img.shields.io/badge/requires-jq-orange.svg)](https://jqlang.org)
[![Agents: 9](https://img.shields.io/badge/agents-9-8A2BE2.svg)](#agents)

Security guardrails and workflow policies for AI coding agents. Blocks dangerous operations at the hook level — not just as instructions.

Supports Claude Code, OpenAI Codex, Kiro, Cursor, Grok, Gemini CLI, GitHub Copilot CLI, Windsurf and Google Antigravity CLI. See [Agents](#agents) for each one, and [docs/configuration.md](docs/configuration.md) for the full list of enforced rules.

## Installation

### Homebrew (macOS and Linux)

```bash
brew tap SumonMSelim/agentguard
brew install agentguard
```

### apt / deb (Debian, Ubuntu, WSL)

Download the latest `.deb` from [GitHub Releases](https://github.com/SumonMSelim/agentguard/releases/latest) and install:

```bash
VERSION=x.y.z   # latest release number, without the leading "v"
curl -LO https://github.com/SumonMSelim/agentguard/releases/download/v${VERSION}/agentguard_${VERSION}_all.deb
sudo dpkg -i agentguard_${VERSION}_all.deb
```

Requires: `jq` (`sudo apt-get install jq`).

### Manual

Requires: `bash`, `jq`.

```bash
# Clone once
git clone https://github.com/SumonMSelim/agentguard.git ~/agentguard

# Bootstrap the `agentguard` CLI (one-time only)
~/agentguard/install.sh claude   # one-time only: bootstraps the `agentguard` CLI wrapper into ~/.local/bin
```

The script installs the `agentguard` wrapper to `~/.local/bin/`. If that is not in your `PATH`, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Install guardrails

After any of the methods above, install guardrails for your agents:

```bash
agentguard <agent>   # one agent, e.g. agentguard claude (see Agents below)
agentguard all       # every supported agent
```

Common options:

```bash
--dry-run                              # preview changes without writing anything
--skills none                          # skip skill packs
--skills karpathy-guidelines,other     # append specific skills only
--project                              # install to current project directory (skills only)
```

Re-running is safe — existing files are backed up with a timestamp suffix. `settings.json` is merged, not overwritten.

## Agents

Install, check and activate each agent. Click an agent to expand it.

<details>
<summary><strong>Claude Code</strong></summary>

**Install**

```bash
agentguard claude
```

**Check**

```bash
agentguard check claude
```

**Activate**

Start a new Claude Code session. Hooks load when a session starts.

**Notes**

- Hooks, deny rules, `attribution` and `includeGitInstructions` are merged into `~/.claude/settings.json`. Your own keys are kept, and uninstall removes only what agentguard added.
- Global rules go to `~/.claude/CLAUDE.md`.
- Docs: [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks).

</details>

<details>
<summary><strong>OpenAI Codex</strong></summary>

**Install**

```bash
agentguard codex
```

**Check**

```bash
agentguard check codex
```

**Activate**

Open Codex, run `/hooks` and approve the agentguard hooks. They stay off until you do.

**Notes**

- Hooks are merged into `~/.codex/hooks.json` (your own hooks are kept) and the scripts go to `~/.codex/hooks/`. Global rules go to `~/.codex/AGENTS.md`.
- File edits through `apply_patch` are checked by the self-edit hook only, since the payload holds patch text, not a file path.
- An agentguard-created `~/AGENTS.md` from older releases is moved to `~/.codex/AGENTS.md` (left in place while Grok is installed).
- Docs: [OpenAI Codex](https://github.com/openai/codex).

</details>

<details>
<summary><strong>Kiro</strong></summary>

**Install**

```bash
agentguard kiro
```

**Check**

```bash
agentguard check kiro
```

**Activate**

- **Kiro CLI 3.x** (`kiro-cli --v3`): nothing to do. Hooks in `~/.kiro/hooks/agentguard.json` apply to every agent. Use interactive mode; Kiro does not load hooks with `--no-interactive`.
- **Kiro CLI 2.x**: switch to the `agentguard` agent. Hooks live in its agent config (`~/.kiro/agents/agentguard.json`) and run only under that agent.

**Notes**

- Both hook formats are installed, so the same install works for 2.x and 3.x. Shell hooks are registered under both `shell` and `execute_bash`.
- Global rules go to `~/.kiro/KIRO.md`.
- Docs: [Kiro hooks](https://kiro.dev/docs/hooks/).

</details>

<details>
<summary><strong>Cursor</strong></summary>

**Install**

```bash
cd /path/to/project
agentguard cursor           # this project: .cursor/ (hooks + AGENTS.md)
agentguard cursor --user    # every project: hooks in ~/.cursor/
```

**Check**

```bash
agentguard check cursor          # from the project root
agentguard check cursor --user
```

**Activate**

Nothing to do.

**Notes**

- `hooks.json` is merged: your own hooks are kept, ours are refreshed on every re-run, and uninstall removes only ours.
- Registered events: `beforeShellExecution`, `beforeReadFile`, `preToolUse` (`Write|Delete`), `beforeMCPExecution`, `postToolUse`.
- `--user` installs hooks only, because Cursor has no user-level instruction file. It is tracked for `agentguard upgrade`. Project installs are not tracked: re-run `agentguard cursor` in each project after upgrading.
- Docs: [Cursor hooks](https://cursor.com/docs/agent/hooks).

</details>

<details>
<summary><strong>Grok</strong></summary>

**Install**

```bash
agentguard grok
```

**Check**

```bash
agentguard check grok
```

**Activate**

Nothing to do.

**Notes**

- Native hooks via `~/.grok/hooks/agentguard.json` plus the shared scripts. Global rules go to `~/AGENTS.md`.
- Grok also loads Claude and Cursor locations for compatibility.
- Docs: [Grok](https://x.ai).

</details>

<details>
<summary><strong>Gemini CLI</strong></summary>

**Install**

```bash
agentguard gemini
```

**Check**

```bash
agentguard check gemini
```

**Activate**

Nothing to do. Hooks are on by default in Gemini CLI v0.26.0 and later. `hooksConfig.enabled: false` turns them all off, and `agentguard check gemini` reports it.

**Notes**

- Hooks are merged into the `hooks` key of `~/.gemini/settings.json` (your settings and hooks are kept, uninstall removes only ours). The scripts go to `~/.gemini/hooks/`. Global rules go to `~/.gemini/GEMINI.md`.
- Registered: `BeforeTool` for `run_shell_command` and the file tools (`read_file`, `write_file`, `replace`, `read_many_files`, `glob`, `grep_search`, `list_directory`), `AfterTool` for the audit log.
- Docs: [Gemini CLI hooks](https://geminicli.com/docs/hooks/).

</details>

<details>
<summary><strong>GitHub Copilot CLI</strong></summary>

**Install**

```bash
agentguard copilot
```

**Check**

```bash
agentguard check copilot
```

**Activate**

Nothing to do. If `COPILOT_HOME` is set, Copilot reads from that directory instead of `~/.copilot`, and the install warns you.

**Notes**

- Copilot runs every `*.json` file in `~/.copilot/hooks/`, so agentguard writes its own `~/.copilot/hooks/agentguard.json` and never touches your hook files. Global rules go to `~/.copilot/copilot-instructions.md`.
- Registered: `preToolUse` for `bash`, `apply_patch` (self-edit hook only, the payload is patch text) and the file tools (`view`, `create`, `edit`, `str_replace_editor`, `grep`, `rg`, `glob`), `postToolUse` for the audit log.
- Agents may not edit `.github/copilot/settings.json` or `settings.local.json`, since `disableAllHooks` there turns off every hook for the repository.
- Hook timeouts are fail-open in Copilot CLI.
- Docs: [Copilot CLI hooks](https://docs.github.com/en/copilot/reference/hooks-configuration).

</details>

<details>
<summary><strong>Windsurf (Cascade)</strong></summary>

**Install**

```bash
agentguard windsurf
```

**Check**

```bash
agentguard check windsurf
```

**Activate**

Nothing to do, but hooks do not run while a workspace is open in Restricted Mode.

**Notes**

- Hooks are merged into `~/.codeium/windsurf/hooks.json` (your hooks are kept, uninstall removes only ours). The scripts go to `~/.codeium/windsurf/hooks/`. Global rules go to `~/.codeium/windsurf/memories/global_rules.md`.
- Registered: `pre_run_command`, `pre_read_code`, `pre_write_code`, `pre_mcp_tool_use`, and the matching `post_*` events for the audit log.
- Windsurf limits global rules to 6,000 characters, so a skill that would pass the limit is skipped with a warning. The default `karpathy-guidelines` does not fit next to the base rules. Add skills per project with `agentguard windsurf --project`, which writes `AGENTS.md`.
- Workspace hooks (`.devin/hooks.json`, legacy `.windsurf/hooks.json`) are not written, but agents may not edit them.
- Docs: [Cascade hooks](https://docs.devin.ai/desktop/cascade/hooks).

</details>

<details>
<summary><strong>Google Antigravity CLI</strong></summary>

**Install**

```bash
agentguard antigravity
```

**Check**

```bash
agentguard check antigravity
```

**Activate**

Restart `agy`, run `/hooks` and confirm the `agentguard` hooks are listed.

**Notes**

- Hooks are an `agentguard` entry in `~/.gemini/config/hooks.json` (your other entries are kept, a re-run resets ours, uninstall removes only ours). The scripts go to `~/.gemini/config/hooks/`. Global rules go to `~/.gemini/AGENTS.md` (24,000-byte limit; skills that would pass it are skipped).
- The hooks file is shared with the Antigravity app and IDE, so the hooks run there too.
- Registered: `PreToolUse` for `run_command` and the file tools (`view_file`, `write_to_file`, `replace_file_content`, `multi_replace_file_content`, `list_dir`, `find_by_name`, `grep_search`), `PostToolUse` for the audit log. A block prints `{"decision":"deny"}`; an allow prints nothing, so your own permission settings still apply.
- Gemini CLI uses other files in `~/.gemini`, so both can be installed. With both, Antigravity also reads `~/.gemini/GEMINI.md` and loads the rules twice.
- MCP tool calls are not checked, because their tool names are not documented.
- Docs: [Antigravity hooks](https://antigravity.google/docs/hooks).

</details>

## Uninstall

```bash
agentguard uninstall claude
agentguard uninstall all
agentguard uninstall claude --dry-run   # preview first
```

Removes only what agentguard owns: its hooks and hook entries, and the instruction file if agentguard created it (otherwise only its skill sections). Merged config files keep your own keys and hooks. The `~/.local/bin/agentguard` CLI wrapper is removed only by `agentguard uninstall all`, so the command keeps working for the agents you still have.

## Check installation status

```bash
agentguard check claude
agentguard check all
```

Reports which hooks, files, settings, and CLI wrapper are present or missing. Exits 1 if anything is out of order — useful in CI to assert guardrails are in place.

## Disable per directory

For throwaway projects (pet projects, POCs, sandboxes) where you want the AI to have full access, disable agentguard for that directory:

```bash
# In the project root, in your shell (NOT inside Claude):
agentguard disable          # disable in current dir
agentguard enable           # re-enable
agentguard status           # show state for current dir

# Or target another path:
agentguard disable /path/to/poc
agentguard enable  /path/to/poc
```

Disabling adds the absolute path to `~/.agentguard/disabled-dirs`. Every hook reads that file on each tool call and short-circuits (no-op) when the active directory matches an entry or sits below one. Other directories keep their guardrails.

**Gated:** `agentguard disable` requires an interactive terminal and asks you to type `yes`, read from `/dev/tty` rather than stdin, so no agent can run it. It also refuses inside a Claude Code session (`CLAUDECODE=1`), and the `block-self-edit` hook blocks `agentguard disable` / `install.sh disable` for every agent. Only you can disable, from your own shell. `agentguard disable --dry-run` previews without asking. Re-enabling is open.

## Upgrade

```bash
agentguard upgrade
```

Pulls the latest agentguard, then uninstalls and reinstalls every agent you previously set up — in one step. Your own `settings.json` keys, your protected-branch choice, your own instruction-file content and your selected skills are preserved: skill sections are stripped and re-applied from the new release. An instruction file that agentguard created is replaced with the new version, so edits you made inside it survive only in the timestamped `.bak` copy. Project-level Cursor installs are not tracked (see [Cursor](#agents)).

On a `.deb` install, the upgrade downloads `SHA256SUMS` from the same release and aborts if the package checksum does not match.

To check if an update is available without upgrading:

```bash
agentguard check claude
# prints an update notice if a newer version exists
```

## Skills

Skills are behavioural packs appended to the agent's instruction file at install time. `core` skills are included when `--skills` is omitted; all others are opt-in via `--skills`. An explicit `--skills` list installs only the skills it names.

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

`--project` appends skills to the instruction file in the **current directory** instead of `~`. No hooks or settings changes — skills only. Requires `agentguard` CLI (installed on any global install).

| Agent       | File written                                          | Notes                            |
|-------------|-------------------------------------------------------|----------------------------------|
| Claude Code | `.claude/CLAUDE.md` in CWD                            |                                  |
| Codex       | `AGENTS.md` in CWD                                    |                                  |
| Cursor      | `.cursor/` in CWD (hooks + `AGENTS.md`)               | Always project-local; full install |
| Grok        | `AGENTS.md` in CWD                                    | Hooks global only (project rules supported) |
| Gemini CLI  | `GEMINI.md` in CWD                                    |                                  |
| Copilot CLI | `.github/copilot-instructions.md` in CWD              |                                  |
| Windsurf    | `AGENTS.md` in CWD                                    | Root `AGENTS.md` is an always-on workspace rule |
| Antigravity | `AGENTS.md` in CWD                                    | Workspace rule file              |
| Kiro        | —                                                     | Not supported; prints warning    |

```bash
# All agents at once — recommended:
agentguard all --project --skills go,aws

# Or one agent (file per the table above):
agentguard claude --project --skills go,aws

# Preview without writing:
agentguard all --project --skills go,aws --dry-run
```

Claude Code loads both `~/.claude/CLAUDE.md` (global) and `.claude/CLAUDE.md` (project) simultaneously — project skills layer on top. Codex loads `~/.codex/AGENTS.md` (global) plus the project `AGENTS.md`. Cursor reads only the project-local `AGENTS.md`.

**Recommended pattern:** install `core` skills globally (guardrails apply everywhere), add language and cloud skills per project where relevant.

### Adding a skill

Create `skills/<name>/SKILL.md` with YAML frontmatter (`name`, `tags`, `description`, `license`) followed by markdown content. Tag `core` to auto-include on every install. The installer picks it up automatically — no registration needed.

## Notes

- **`block-env.sh`** — best-effort on the bash surface. `block-env-read.sh` is the primary layer (intercepts Read/Write/Edit tools directly).
- **Protected branches** — install prompts for which branches to protect from direct commit/push (default: `main,master`). Your answer is saved to `~/.agentguard/config` and applies across all agents. Override per-shell with `export AGENTGUARD_PROTECTED_BRANCHES="main,master,develop"`.

→ [Configuration reference](docs/configuration.md) — protected branches, settings.json merge rules, audit log rotation.

## License

[MIT](LICENSE)
