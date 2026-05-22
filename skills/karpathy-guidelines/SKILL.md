---
name: karpathy-guidelines
tags: [core]
description: Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria.
license: MIT
source: https://github.com/forrestchang/andrej-karpathy-skills
---

# Karpathy Guidelines

Derived from Andrej Karpathy's observations on common LLM coding mistakes.
Biases toward caution over speed. Apply judgment on trivial tasks.

## 1. Think before coding
- State assumptions explicitly. Uncertain → ask before proceeding
- Multiple interpretations → present them, don't pick silently
- Simpler approach exists → say so and push back
- Unclear requirement → stop, name what's confusing, ask
- Unknown API, method, or type → verify existence before using. Never hallucinate interfaces

## 2. Simplicity first
- No features beyond what was asked
- No abstractions for single-use code
- No unrequested "flexibility" or "configurability"
- No error handling for impossible scenarios
- 200 lines that could be 50 → rewrite it

## 3. Surgical changes
When editing existing code:
- Don't improve adjacent code, comments, or formatting
- Don't refactor things that aren't broken
- Match existing style even if you'd do it differently
- Unrelated dead code → mention it, don't delete it

When your changes create orphans:
- Remove imports/variables/functions YOUR changes made unused
- Don't remove pre-existing dead code unless asked

Every changed line must trace directly to the user's request.

## 4. Destructive operations
- Deletes, drops, truncates, overwrites → confirm explicitly before executing
- Irreversible actions → state what will be lost and wait for approval
- When in doubt, show the plan, don't run it

## 5. Goal-driven execution
Transform tasks into verifiable goals before starting:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan first:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria → loop independently to completion.
