#!/bin/bash
# PostToolUse hook: auto-format Python files after Edit/Write.
#
# Reads the Claude hook event JSON from stdin, extracts the file path, and
# runs isort + black if (a) the file is .py and (b) a usable pipenv venv exists
# in this repo. Silently no-ops otherwise — never blocks the edit.
#
# Hard guarantee: always exits 0. The hook is best-effort and must never
# interfere with the user's edit, even on malformed input or missing tools.

# Hook input JSON on stdin
input=$(cat 2>/dev/null || true)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

# Bail if no file path or not Python
if [ -z "${file_path:-}" ]; then exit 0; fi
case "$file_path" in
  *.py) ;;
  *) exit 0 ;;
esac

# Bail if the file no longer exists (deleted, etc.)
[ -f "$file_path" ] || exit 0

# Find repo root (the dir containing the .claude folder this hook lives in)
repo_root="${CLAUDE_PROJECT_DIR:-$(dirname "$(dirname "$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")")" 2>/dev/null)}"
[ -z "$repo_root" ] && exit 0
[ -d "$repo_root" ] || exit 0

# Only attempt formatting if pipenv venv looks usable
cd "$repo_root" 2>/dev/null || exit 0
[ -f Pipfile ] || exit 0

# Try formatting — capture but ignore errors so we never block the edit
pipenv run isort "$file_path" >/dev/null 2>&1 || true
pipenv run black --quiet "$file_path" >/dev/null 2>&1 || true

exit 0
