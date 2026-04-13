#!/bin/bash
# hooks/block-main-branch.sh
#
# 1. Blocks any force-push flag (--force, -f, --force-with-lease) in git push.
# 2. Blocks git commit and git push when the current branch is main or master.
# 3. Blocks explicit pushes targeting main/master regardless of current branch,
#    including refspec-style pushes (HEAD:main, refs/heads/main).
#
# Shared hook — used by both Claude (Bash tool) and Kiro (execute_bash tool).
# Static deny rules cannot inspect git state — this hook runs in the actual
# working directory so it can call git at runtime.
#
# Exit 2 = blocked. The agent receives the stderr message as feedback.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""') || exit 0

# Only act on git commit or git push commands (anywhere in the string to catch chained commands)
if ! echo "$COMMAND" | grep -qE '\bgit\s+(commit|push)\b'; then
  exit 0
fi

# Block any force-push flag, regardless of its position in the command
if echo "$COMMAND" | grep -qE '\s(-f|--force|--force-with-lease(=\S*)?)\b'; then
  echo "Blocked: force push is not permitted in any form." >&2
  echo "Rewrite history locally if needed, then open a PR instead of force-pushing." >&2
  exit 2
fi

# Detect current branch.
# Note: in detached HEAD state --show-current returns an empty string, so the
# branch checks below are skipped. Committing in detached HEAD creates an
# anonymous commit on no branch; this is intentionally not blocked.
BRANCH=$(git branch --show-current 2>/dev/null)

if echo "$BRANCH" | grep -qE '^(main|master)$'; then
  echo "Blocked: currently on '$BRANCH'. Never commit or push directly to '$BRANCH'." >&2
  echo "Steps to follow:" >&2
  echo "  1. git pull origin $BRANCH" >&2
  echo "  2. git checkout -b <type>/<short-description>" >&2
  echo "  3. Make changes and commit on that branch" >&2
  echo "  4. When ready, open a PR to merge back into $BRANCH" >&2
  exit 2
fi

# Also block explicit pushes targeting main/master regardless of current branch,
# including refspec syntax like HEAD:main or refs/heads/main.
# Uses [: ] (colon or space) rather than [:\s] — \s is not interpreted as whitespace
# inside bracket expressions by BSD/GNU grep -E, so a space literal is required.
# Uses (\s|$) after the branch name so trailing flags like --tags don't bypass the check.
if echo "$COMMAND" | grep -qE 'git push[[:space:]]+.*[: ](refs/heads/)?(main|master)([[:space:]]|$)'; then
  echo "Blocked: pushing directly to main/master is not permitted." >&2
  echo "Open a PR instead." >&2
  exit 2
fi

exit 0
