## Summary

<!-- What does this PR do? One paragraph. -->

## Type of change

- [ ] Bug fix
- [ ] New feature (hook / skill / agent)
- [ ] Refactor / improvement
- [ ] Documentation
- [ ] CI / tooling

## Checklist

- [ ] `bash tests/run_all.sh` passes locally
- [ ] New or changed behaviour has test coverage
- [ ] Instruction files in sync (`bash tests/check-sync.sh`) — required if `agents/claude/CLAUDE.md` was changed
- [ ] `AGENTGUARD_HOOKS` array updated in `install.sh` — required if a hook was added or removed
- [ ] No secrets, credentials, or `.env` files included
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)

## Testing

<!-- How was this tested? What cases does it cover? What was deliberately left out? -->

## Security considerations

<!-- Does this change affect what agentguard blocks or allows? Any new file writes or shell executions introduced? -->
