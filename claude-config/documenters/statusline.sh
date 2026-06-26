#!/usr/bin/env bash
# Status line for documenters. Reads JSON on stdin, prints one line.
# Shows: branch · ticket · git dirty count · model · ctx% · cost
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

input=$(cat)

branch=$(echo "$input" | jq -r '.git_branch // .workspace.git_branch // ""' 2>/dev/null)
model=$(echo "$input" | jq -r '.model.display_name // .model // "?"' 2>/dev/null)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // .total_cost // 0' 2>/dev/null)
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // .context.percent_used // .context_fill_percent // empty' 2>/dev/null)

# Fall back to live git if harness didn't supply branch.
if [[ -z "$branch" || "$branch" == "null" ]]; then
  branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
fi

# Extract ticket key (DOC-XXXX) from branch if present.
ticket=""
if [[ "$branch" =~ doc-([0-9]+) ]]; then
  ticket=" · DOC-${BASH_REMATCH[1]}"
fi

# Dirty count.
dirty=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
dirty_str=""
[[ "$dirty" != "0" && -n "$dirty" ]] && dirty_str=" ●$dirty"

ctx_str=""
if [[ -n "$ctx_pct" && "$ctx_pct" != "null" ]]; then
  pct=$(printf "%.0f" "$ctx_pct" 2>/dev/null || echo "?")
  ctx_str=" · ctx ${pct}%"
fi

cost_str=""
if [[ -n "$cost" && "$cost" != "0" && "$cost" != "null" ]]; then
  cost_str=$(printf " · \$%.3f" "$cost" 2>/dev/null || echo "")
fi

printf "%s%s%s · %s%s%s\n" "${branch:-no-branch}" "$ticket" "$dirty_str" "$model" "$ctx_str" "$cost_str"
