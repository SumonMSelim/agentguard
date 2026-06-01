# Release Process

Releases are fully automated via `workflow_dispatch`. One-time setup required for the Homebrew tap deploy key.

## One-time setup: TAP_DEPLOY_KEY secret

The release workflow pushes the updated Homebrew formula to the `homebrew-agentguard` tap repo using an SSH deploy key.

### 1. Generate a keypair (no passphrase)

```bash
ssh-keygen -t ed25519 -C "agentguard-tap-deploy" -f /tmp/tap_deploy_key -N ""
```

### 2. Add the public key to the tap repo

Go to: https://github.com/SumonMSelim/homebrew-agentguard/settings/keys/new

- Title: `agentguard release bot`
- Key: paste contents of `/tmp/tap_deploy_key.pub`
- Check **Allow write access**
- Click **Add key**

### 3. Add the private key as a secret in this repo

Go to: https://github.com/SumonMSelim/agentguard/settings/secrets/actions/new

- Name: `TAP_DEPLOY_KEY`
- Value: paste contents of `/tmp/tap_deploy_key`
- Click **Add secret**

### 4. Delete the local keypair

```bash
rm /tmp/tap_deploy_key /tmp/tap_deploy_key.pub
```

---

## Releasing a new version

```bash
gh workflow run release.yml -f version=1.5.0
```

Or via GitHub UI: Actions → release → Run workflow → enter version.

### What happens automatically

1. Validates version is valid semver and greater than current
2. Runs full test suite — aborts if any test fails
3. Bumps `VERSION`, commits and pushes to main
4. Creates annotated tag `v1.5.0`
5. Builds `agentguard_1.5.0_all.deb`, creates GitHub Release, attaches artifact
6. Computes tarball SHA256, updates `homebrew/Formula/agentguard.rb`, commits to main
7. Pushes updated formula to `homebrew-agentguard` tap repo

### Monitor progress

```bash
gh run list --workflow=release.yml --limit 5
gh run watch <run-id>
```
