#!/usr/bin/env bash
# PostToolUse hook: auto-format Python files after Edit/Write/MultiEdit.
# Reads the Claude Code hook JSON payload from stdin, extracts file_path,
# runs black + isort on that single file if it qualifies.
# Always exits 0 — a formatting failure should never block the agent.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLACK="$REPO_ROOT/.venv/bin/black"
ISORT="$REPO_ROOT/.venv/bin/isort"

# No venv → nothing to do.
[[ -x "$BLACK" && -x "$ISORT" ]] || exit 0

file_path="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"

# Bail if no file, not a .py, in migrations, in vendor, or outside documenters/.
[[ -n "$file_path" ]] || exit 0
[[ "$file_path" == *.py ]] || exit 0
[[ "$file_path" == *"/migrations/"* ]] && exit 0
[[ "$file_path" == *"/vendor/"* ]] && exit 0
[[ "$file_path" == "$REPO_ROOT/documenters/"* ]] || exit 0
[[ -f "$file_path" ]] || exit 0

"$BLACK" --quiet "$file_path" >/dev/null 2>&1 || true
"$ISORT" --quiet "$file_path" >/dev/null 2>&1 || true

exit 0
