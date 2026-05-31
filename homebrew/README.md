# Homebrew Tap — agentguard

This directory contains the Homebrew formula for agentguard.

## Publishing the tap

The formula must live in a **separate GitHub repository** named `homebrew-agentguard` under the same account:

```
github.com/SumonMSelim/homebrew-agentguard/
└── Formula/
    └── agentguard.rb
```

### One-time setup

1. Create the repo: https://github.com/new → name it `homebrew-agentguard`
2. Copy `Formula/agentguard.rb` into it
3. Push to `main`

Users can then install with:

```bash
brew tap SumonMSelim/agentguard
brew install agentguard
```

Or in one command:

```bash
brew install SumonMSelim/agentguard/agentguard
```

## Updating the formula for a new release

After tagging a new release (e.g. `v1.4.0`):

1. Get the new tarball SHA256:
   ```bash
   curl -sL https://github.com/SumonMSelim/agentguard/archive/refs/tags/v1.4.0.tar.gz | shasum -a 256
   ```

2. Update `Formula/agentguard.rb`:
   - `url` → new tag URL
   - `sha256` → output from step 1
   (Do NOT add an explicit `version` field — Homebrew infers it from the URL tag)

3. Commit and push to `homebrew-agentguard`:
   ```bash
   git commit -m "feat: bump agentguard to v1.4.0"
   git push
   ```

Homebrew users get the update on their next `brew upgrade`.
