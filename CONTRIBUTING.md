# Contributing to agentguard

Thanks for your interest in contributing. This guide covers everything you need to get started.

## Before you start

- Check [existing issues](https://github.com/SumonMSelim/agentguard/issues) and [pull requests](https://github.com/SumonMSelim/agentguard/pulls) to avoid duplicating work.
- For significant changes (new hooks, new agents, architecture changes), open an issue first to discuss the approach before writing code.
- For small fixes (typos, test improvements, documentation), go ahead and open a PR directly.

## Requirements

- `bash` (4.0+)
- `jq`
- No other runtime dependencies — keep it that way.

## Getting started

```bash
git clone https://github.com/SumonMSelim/agentguard.git
cd agentguard
bash tests/run_all.sh   # all suites must pass before you start
```

## What you can contribute

### New hooks

Hooks live in `hooks/`. Each hook:
- Reads a JSON payload from stdin
- Exits `2` to block, `0` to allow, `1` on error
- Handles both Claude/Kiro (`tool_input.command`) and Cursor (`command`) payload shapes
- Must have corresponding tests in `tests/claude.sh` and `tests/kiro.sh`

See existing hooks for the pattern. Add the new hook name to `AGENTGUARD_HOOKS` in `install.sh`.

### New skills

Skills live in `skills/<name>/SKILL.md` with YAML frontmatter:

```yaml
---
name: skill-name
tags: [tag1, tag2]   # add "core" to auto-include on every install
description: One-line description
license: MIT
---
```

Followed by markdown content. No registration needed — `install.sh` picks it up automatically.

### New agent support

Each agent lives in `agents/<name>/`. At minimum:
- An instruction file (CLAUDE.md / KIRO.md / AGENTS.md equivalent)
- A settings/config file wiring up the hooks
- Install and uninstall functions in `install.sh`
- A test suite in `tests/<agent>.sh`
- Sync rules updated in `tests/check-sync.sh` if the instruction file must match others

### Bug fixes and improvements

- Match the existing code style (bash, no external deps beyond `jq`)
- Keep changes surgical — don't refactor unrelated code
- Update tests to cover what you changed

## Running tests

```bash
bash tests/run_all.sh          # all suites
bash tests/claude.sh           # Claude hook logic only
bash tests/claude.sh hooks     # hook tests only (faster)
bash tests/uninstall.sh        # uninstall/clean-state tests
bash tests/check-sync.sh       # instruction file sync check
```

All suites must pass before opening a PR. CI runs `tests/run_all.sh` on every push.

## Pull request checklist

- [ ] `bash tests/run_all.sh` passes locally
- [ ] New behaviour has test coverage
- [ ] `CLAUDE.md`, `KIRO.md`, `agents/cursor/AGENTS.md` are in sync if you changed the instruction file (run `tests/check-sync.sh`)
- [ ] `AGENTGUARD_HOOKS` array updated in `install.sh` if you added a hook
- [ ] No secrets, credentials, or `.env` files committed
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)

## Commit message format

```
<type>[optional scope]: <short description>
```

Types: `feat` | `fix` | `docs` | `style` | `refactor` | `perf` | `test` | `chore`

Examples:
```
feat(hooks): add block-secrets-in-code hook
fix(install): skip branch prompt during upgrade loop
docs: add contributing guide
```

## Security issues

**Do not open a public issue for security vulnerabilities.** See [SECURITY.md](SECURITY.md) for the responsible disclosure process.

## Code of Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
