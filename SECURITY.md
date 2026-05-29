# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| Latest release | ✅ Yes |
| Older releases | ❌ No — upgrade to latest |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security issue in agentguard — including but not limited to:
- A hook bypass that allows a blocked operation to execute
- Shell injection in hook logic or the installer
- A way to exfiltrate secrets that agentguard is supposed to protect
- An unsafe file write or privilege escalation in `install.sh`

Please report it privately via [GitHub's private vulnerability reporting](https://github.com/SumonMSelim/agentguard/security/advisories/new).

Include:
1. A description of the vulnerability
2. Steps to reproduce
3. The potential impact
4. Any suggested fix (optional)

## What to expect

- **Acknowledgement** within 3 business days
- **Assessment** (confirmed / not a bug / won't fix) within 7 days
- **Fix and release** as soon as possible for confirmed issues, with credit to the reporter in the release notes (unless you prefer to remain anonymous)

## Scope

agentguard is a security tool — any bypass of its enforcement hooks is in scope. The following are **not** in scope:
- Vulnerabilities in the agents agentguard protects (Claude Code, Kiro, Cursor, Codex)
- Issues requiring physical access to the machine
- Social engineering

## Philosophy

agentguard's hooks operate at the shell level. They are a defence-in-depth layer, not a security boundary that can guarantee isolation. A determined user with shell access can always disable them. The goal is to prevent accidental or agent-initiated dangerous operations, not to protect against a hostile local user.
