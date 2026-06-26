#!/usr/bin/env bash
# PreToolUse hook on Bash: block direct invocations of pytest/black/isort/flake8.
# Convention in this repo: always go through `make test-py` / `make lint` / `make fix-lint`.
# Exit 2 with a message blocks the tool call and surfaces the message to the agent.

set -u

cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -n "$cmd" ]] || exit 0

# Strip leading env-var assignments (FOO=bar BAZ=qux cmd …) so prefixes like
# `PIPENV_IGNORE_VIRTUALENVS=1 PIPENV_VENV_IN_PROJECT=true pipenv run pytest …` are caught.
stripped="$cmd"
while [[ "$stripped" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
  stripped="${stripped#${BASH_REMATCH[0]}}"
done

# Strip leading "pipenv run " so we catch `pipenv run pytest …` too.
stripped="${stripped#pipenv run }"

# Match the bare tool name as the first whitespace-delimited token.
first="${stripped%% *}"
case "$first" in
  pytest|black|isort|flake8)
    echo "Blocked: invoke '$first' via Make instead." >&2
    echo "  pytest  → make test-py TESTS='...'" >&2
    echo "  black/isort/flake8 → make lint  (check)  or  make fix-lint  (auto-fix)" >&2
    exit 2
    ;;
esac

exit 0
