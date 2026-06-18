#!/bin/bash
# hooks/_check-disabled.sh
#
# Sourced (NOT executed) by every guardrail hook. If the current directory
# is in the agentguard disabled list, exits 0 — short-circuiting the host
# hook so all its checks are skipped.
#
# The disabled list lives at ~/.agentguard/disabled-dirs, one absolute path
# per line. A directory matches if it equals an entry, or is below one
# (ancestor disables descendants). Blank lines and `#` comments ignored.
#
# Override the path with AGENTGUARD_DISABLED_DIRS_FILE (test seam).
#
# Disabling is gated to the user via `agentguard disable` (which refuses to
# run inside Claude Code). Re-enabling is open — restoring guardrails can't
# hurt.

_agentguard_disabled_file="${AGENTGUARD_DISABLED_DIRS_FILE:-$HOME/.agentguard/disabled-dirs}"
if [[ -f "$_agentguard_disabled_file" ]]; then
  _agentguard_cur="$(pwd -P 2>/dev/null || pwd)"
  while IFS= read -r _agentguard_line || [[ -n "$_agentguard_line" ]]; do
    _agentguard_line="${_agentguard_line%$'\r'}"
    _agentguard_line="${_agentguard_line#"${_agentguard_line%%[![:space:]]*}"}"
    _agentguard_line="${_agentguard_line%"${_agentguard_line##*[![:space:]]}"}"
    [[ -z "$_agentguard_line" || "${_agentguard_line:0:1}" == "#" ]] && continue
    if [[ "$_agentguard_cur" == "$_agentguard_line" || "$_agentguard_cur" == "$_agentguard_line"/* ]]; then
      unset _agentguard_disabled_file _agentguard_cur _agentguard_line
      exit 0
    fi
  done < "$_agentguard_disabled_file"
  unset _agentguard_cur _agentguard_line
fi
unset _agentguard_disabled_file
