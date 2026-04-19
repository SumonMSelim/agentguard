# Global Rules — Apply to Every Project

---

## 🔒 Secrets & Environment Variables

- NEVER read `.env`, `.env.*`, `.env.local`, `.env.production`, `.env.staging`, or any equivalent.
- NEVER run `printenv` or bare `env`.
- NEVER read `~/.ssh/`, `~/.aws/`, `credentials`, or any `secrets/` directory.
- NEVER run `gh auth token`.
- Need an API key? Ask the user. Don't search for it.
- No workarounds to these rules.

---

## 🔁 Git Workflow

### Always ask before:
- `git commit`, `git push`, opening or merging a PR
- Any force push (`--force`, `-f`, `--force-with-lease`) — always blocked
- `git reset --hard`, `git clean -f`, `git branch -D`
- `git stash drop` / `git stash clear`

### Branch discipline
- Check current branch first: `git branch --show-current`
- On `main`/`master`: pull, then create a feature branch
  - `git checkout -b <type>/<short-description>`
- NEVER commit or push directly to `main`/`master`

### Commit messages — Conventional Commits
```
<type>[optional scope]: <short description>
```
Types: `feat` | `fix` | `docs` | `style` | `refactor` | `perf` | `test` | `chore` | `build` | `ci` | `revert`

- Subject ≤ 72 chars, lowercase, no trailing period
- Body: explain WHY, not WHAT
- Breaking changes: `BREAKING CHANGE:` in footer
- No vague messages: "fix stuff", "WIP", "update", "changes"

### Attribution
- NEVER add AI/tool attribution to commits, PR descriptions, or code comments.

---

## 🐳 Runtime & Dependencies

- ALWAYS use Docker to run code. Never execute directly on the host.
- Existing `Dockerfile`/`compose.yml`? Use it. None? Create a minimal one first.
- Quick one-off? Use `docker run` with an official image.
- NEVER install system-wide without explicit permission:
  - No `brew`, `apt`, `yum`, `apk`
  - No `npm -g`, `yarn global`, `pnpm -g`
  - No `pip install` outside Docker or active virtualenv
  - No `gem install` (system), `cargo install` to system paths
- NEVER pipe-to-shell (`curl | bash`, `wget | sh`). Download first, inspect, then run.
- Unsure if system install needed? Ask first.

---

## 🖥️ Shell Environment

- Start of shell session: read `~/.zshrc` or `~/.bashrc` to understand aliases.
- Command behaves unexpectedly? Check if it's aliased. Use aliased syntax or full path.

---

## 🧠 Planning & Approach

**Think before coding. State assumptions. Surface tradeoffs.**

- Uncertain about requirements → ask one focused question. Don't guess and implement.
- Multiple interpretations → present them, don't pick silently.
- Simpler approach exists → say so. Push back when warranted.
- Task touches >3 files or involves architecture → share a brief plan first, wait for approval.
- Irreversible action (delete files, drop data, schema change) → say so explicitly, wait for confirmation.

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- 200 lines that could be 50 → rewrite it.

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- Unrelated dead code → mention it, don't delete it.
- Remove imports/variables/functions YOUR changes made unused.

**Define success criteria. Loop until verified.**

- Transform tasks into verifiable goals before starting.
- Multi-step tasks → state a brief plan: `[Step] → verify: [check]`
- Strong success criteria → loop independently. Weak criteria → ask first.

---

## ✅ Code Quality

- Match existing style, naming, and patterns. Flag new patterns before introducing them.
- Write or update tests for any logic you add or change. No exceptions for "small changes."
- No debug statements or commented-out dead code in final output.
- Bug outside current task scope → point it out, don't fix it unless asked.
- Follow OWASP and relevant security best practices.
- Apply DRY, KISS, SOLID where it makes sense. Don't over-engineer.

---

## 💬 Communication

- No preamble: skip "Certainly!", "Great question!", "Of course!".
- Direct and concise. Summarize at the end, don't pad.
- Can't do something due to a rule → say so briefly and explain why.
- Context compacted → re-read this file and restate current task.
