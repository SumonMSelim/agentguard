# Global Rules — Apply to Every Project

---

## 🔒 Security: Secrets & Environment Variables

- NEVER read, print, reference, or pass to another tool the contents of `.env`, `.env.*`, `.env.local`, `.env.production`, `.env.staging`, or any equivalent file.
- NEVER run `printenv`, or bare `env` to dump environment variables.
- NEVER read `~/.ssh/`, `~/.aws/`, `credentials`, or any `secrets/` directory.
- NEVER run `gh auth token` — it exposes the GitHub authentication token.
- If a task requires an API key or secret value, ask the user to supply it explicitly in the conversation — do not search for it.
- Do NOT suggest workarounds to these restrictions.

---

## 🔁 Git Workflow

### Always ask before:
- `git commit` — even if earlier in the conversation the user said "go ahead"
- `git push` — to any remote or branch
- Opening or merging a Pull Request
- Any force push (`--force`, `-f`, `--force-with-lease`) — these are **always** blocked
- `git reset --hard`, `git clean -f`, `git branch -D` — destructive and hard to reverse
- `git stash drop` / `git stash clear` — permanently destroys stashed work

### Branch discipline
- Before making ANY code changes, check the current branch with `git branch --show-current`.
- If on `main` or `master`:
  1. Run `git pull origin main` (or `master`) to get the latest
  2. Create a feature branch: `git checkout -b <type>/<short-description>`
     e.g. `feat/user-auth`, `fix/payment-null-response`, `chore/update-deps`
  3. Do ALL work on that branch
- NEVER commit directly to `main` or `master`.
- NEVER push to `main` or `master` directly — open a PR instead.
- Branch names should follow the same type prefix as Conventional Commits.

### Commit messages — Conventional Commits
All commit messages must follow https://www.conventionalcommits.org:

```
<type>[optional scope]: <short description>

[optional body — explain WHY, not WHAT]

[optional footer — breaking changes, issue refs]
```

Types: `feat` | `fix` | `docs` | `style` | `refactor` | `perf` | `test` | `chore` | `build` | `ci` | `revert`

Examples:
- `feat(auth): add OAuth2 login with GitHub`
- `fix(payments): handle null response from Stripe webhook`
- `refactor(api): extract pagination logic into shared util`
- `chore: update dependencies`

Rules:
- Subject line ≤ 72 characters, lowercase, no trailing period
- Body explains motivation and context, not the diff
- Mark breaking changes with `BREAKING CHANGE:` in the footer
- Never write vague messages like "fix stuff", "WIP", "update", or "changes"

### Attribution
- NEVER add "Co-authored-by: Claude", "Generated with Claude Code",
  or any AI/tool attribution to commits, PR descriptions, or code comments.

---

## 🐳 Runtime & Dependencies

- ALWAYS use Docker to run any code. Never execute code directly on the host system.
- If a `Dockerfile` or `docker-compose.yml`/`compose.yml` already exists in the project, use it.
- If neither exists, create a minimal appropriate `Dockerfile` before running anything.
- For quick one-off execution, use `docker run` with an official image rather than installing the runtime locally.
- NEVER install anything system-wide without explicit permission:
  - No `brew install`, `apt install`, `apt-get install`, `yum install`, `apk add`
  - No `npm install -g`, `yarn global add`, `pnpm add -g`
  - No `pip install` / `pip3 install` outside a Docker container or active virtualenv
  - No `gem install` (system gems), `cargo install` to system paths
- Project-local installs inside Docker or an active virtualenv are fine.
- NEVER use pipe-to-shell patterns (`curl | bash`, `wget | sh`, etc.) — download
  the script first, inspect it, then run it explicitly.
- When in doubt about whether something requires a system install, ask first.

---

## 🖥️ Shell Environment

- At the start of any session that involves running shell commands, read `~/.zshrc` or `~/.bashrc` (whichever the user's shell uses) to understand available aliases and command overrides.
- If a standard command behaves unexpectedly, check whether it is aliased to a different tool with different flags (e.g. `find` aliased to `fd`, which uses `--type`/`-t` instead of `-type`). Either use the aliased tool's syntax or invoke the full path (e.g. `/usr/bin/find`) to bypass the alias.

---

## 🧠 Planning & Approach

- For any task that will touch more than ~3 files or involves architectural
  decisions: **pause and share a brief plan first** before writing any code.
  Wait for my approval before proceeding.
- If a requirement is ambiguous, ask one focused clarifying question. Don't guess and implement.
- Prefer the simplest solution that solves the problem. Do not over-engineer.
- If you're about to do something irreversible (delete files, drop data, restructure a schema), say so explicitly and wait for confirmation.

---

## ✅ Code Quality

- Match the style, naming conventions, and patterns already present in the codebase.
- Don't introduce a new pattern without flagging it.
- Write or update tests for any logic you add or change. Do not skip tests on the grounds that "it's a small change."
- Do not leave `console.log`, debug statements, or commented-out dead code in the final output unless asked.
- If you notice a bug or problem outside the scope of the current task, point it out — but don't fix it unless asked.
- Always follow OWASP and relevant security best practices.
- Apply DRY, KISS, SOLID principles where applicable and makes sense. Do not over-engineer. When in doubt, ask for confirmation.

---

## 💬 Communication

- Be direct and concise. Skip preamble like "Certainly!" or "Great question!".
- Skip pre-text and post-text, summarize concisely.
- When you can't do something due to a global rule here, say so briefly and explain why. Don't silently skip it.
- When context compacts during a long session, re-read this file and restate your current task to maintain continuity.
