#!/usr/bin/env bash
# SessionStart hook: print situational awareness to session context.
# Output on stdout becomes an additionalContext block injected into the conversation.
# Source: harness sends {session_id, source, cwd, ...} on stdin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

input=$(cat)
source=$(echo "$input" | jq -r '.source // "unknown"' 2>/dev/null)

# Skip on `clear` to avoid spamming after manual reset.
[[ "$source" == "clear" ]] && exit 0

branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
dirty_count=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
recent_commit=$(git -C "$REPO_ROOT" log -1 --format="%h %s" 2>/dev/null || echo "")
ticket=""
[[ "$branch" =~ doc-([0-9]+) ]] && ticket="DOC-${BASH_REMATCH[1]}"

# WIP markdown files at repo root (PLAN_*.md, INVESTIGATE_*.md, STORY_*.md, PR*_REVIEW.md).
wip_files=$(ls -1 "$REPO_ROOT"/{PLAN_*.md,INVESTIGATE_*.md,STORY_*.md,PR*_REVIEW.md,REVIEW.md} 2>/dev/null | xargs -n1 basename 2>/dev/null | head -10)

cat <<EOF
## Session context (auto-loaded)

- **Branch:** \`${branch:-?}\`${ticket:+ · Ticket: }${ticket}
- **Working tree:** ${dirty_count} file(s) modified
- **Last commit:** ${recent_commit}
EOF

if [[ -n "$wip_files" ]]; then
  echo "- **WIP markdown at root:**"
  while IFS= read -r f; do
    [[ -n "$f" ]] && echo "  - \`$f\`"
  done <<< "$wip_files"
fi

echo
echo "_Resume: \`session_start_context\` hook · source=\`${source}\`_"
