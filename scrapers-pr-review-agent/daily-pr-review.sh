#!/usr/bin/env bash
# Daily PR review routine.
# Lists open PRs from 2026 across all active City-Bureau/city-scrapers* repos
# that duongcao-ea has not approved yet (excluding dependabot), then runs the
# /code-review skill on each in parallel via headless `claude -p`. Writes one
# markdown file per PR to ~/pr-reviews/<repo>_PR<num>.md (overwritten daily).

set -u
set -o pipefail

OWNER="City-Bureau"
ME="duongcao-ea"
OUT_DIR="$HOME/pr-reviews"
LOG_DIR="$HOME/pr-reviews/_logs"
TODAY="$(date +%Y-%m-%d)"
LOG_FILE="$LOG_DIR/run-$TODAY.log"
MAX_PARALLEL="${MAX_PARALLEL:-6}"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# Ensure CLI tools resolve under launchd's stripped PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Review one PR. Args: repo num title
review_pr() {
  local repo="$1"
  local num="$2"
  local title="$3"
  local out_file="$OUT_DIR/${repo}_PR${num}.md"
  local task_log="$LOG_DIR/${repo}_PR${num}.log"

  log "  → ${repo} #${num}: ${title}"

  local diff
  diff=$(gh pr diff "$num" --repo "$OWNER/$repo" 2>>"$task_log") || diff=""
  if [ -z "$diff" ]; then
    log "    (empty diff, skipping)"
    return 1
  fi

  local diff_len=${#diff}
  if [ "$diff_len" -gt 200000 ]; then
    diff="${diff:0:200000}

...(diff truncated at 200k chars; original size: $diff_len)"
  fi

  local pr_meta
  pr_meta=$(gh pr view "$num" --repo "$OWNER/$repo" \
    --json title,body,author,baseRefName,headRefName,url 2>>"$task_log") || pr_meta="{}"

  local prompt
  prompt="Run the /code-review skill on this pull request and output the review as markdown.

Repo: $OWNER/$repo
PR #$num
Metadata (JSON):
$pr_meta

Diff:
\`\`\`diff
$diff
\`\`\`

Output the full code review markdown only. Do not include preamble, do not write files yourself, do not run tools — just print the review."

  if claude -p "$prompt" \
       --allowed-tools "Read Glob Grep" \
       --output-format text \
       --no-session-persistence \
       > "$out_file" 2>>"$task_log"; then
    log "    ✓ ${out_file}"
    return 0
  else
    log "    ✗ claude -p failed (see $task_log)"
    return 1
  fi
}

# Need this exported for any subshells, but here we just call inline.
log "Starting daily PR review (MAX_PARALLEL=$MAX_PARALLEL)"

# 1. Discover all active city-scrapers* repos.
REPOS=$(gh repo list "$OWNER" --limit 200 --json name,isArchived \
  | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["name"].startswith("city-scrapers") and not r["isArchived"]:
        print(r["name"])
' | sort)

REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
log "Discovered $REPO_COUNT active repos"

# 2. Collect all PRs to review across all repos into a single work list.
WORK_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE"' EXIT

while read -r repo; do
  [ -z "$repo" ] && continue
  gh pr list --repo "$OWNER/$repo" --state open \
    --search "created:2026-01-01..2026-12-31 -author:app/dependabot" \
    --json number,title,author,reviews 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
me = '$ME'
repo = '$repo'
bots = {'app/dependabot', 'dependabot[bot]', 'dependabot'}
for pr in data:
    author = (pr.get('author') or {}).get('login', '')
    if author in bots:
        continue
    my_reviews = sorted(
        (r for r in pr.get('reviews', [])
         if r.get('author', {}).get('login') == me),
        key=lambda r: r.get('submittedAt') or '',
    )
    if my_reviews and my_reviews[-1].get('state') == 'APPROVED':
        continue
    # Tab-separated: repo<TAB>num<TAB>title
    title = (pr.get('title') or '').replace('\t', ' ').replace('\n', ' ')
    print(f\"{repo}\t{pr['number']}\t{title}\")
" 2>/dev/null >> "$WORK_FILE" || true
done <<< "$REPOS"

PR_COUNT=$(wc -l < "$WORK_FILE" | tr -d ' ')
log "Found $PR_COUNT PRs to review"

if [ "$PR_COUNT" -eq 0 ]; then
  log "Nothing to do."
  exit 0
fi

# 3. Process in parallel with a concurrency cap.
# bash 3.2 doesn't support `wait -n`, so workers report status via files.
SUCCESS_FILE=$(mktemp)
FAIL_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE" "$SUCCESS_FILE" "$FAIL_FILE"' EXIT

run_one() {
  local r="$1" n="$2" t="$3"
  if review_pr "$r" "$n" "$t"; then
    echo "${r}#${n}" >> "$SUCCESS_FILE"
  else
    echo "${r}#${n}" >> "$FAIL_FILE"
  fi
}

while IFS=$'\t' read -r repo num title; do
  [ -z "$repo" ] && continue
  # Throttle: wait while running job count >= MAX_PARALLEL
  while [ "$(jobs -r 2>/dev/null | wc -l | tr -d ' ')" -ge "$MAX_PARALLEL" ]; do
    sleep 0.5
  done
  run_one "$repo" "$num" "$title" &
done < "$WORK_FILE"

wait  # drain remaining background jobs

SUCCESS=$(wc -l < "$SUCCESS_FILE" 2>/dev/null | tr -d ' ')
FAIL=$(wc -l < "$FAIL_FILE" 2>/dev/null | tr -d ' ')
log "Done. Reviewed=${SUCCESS:-0} Failed=${FAIL:-0} Total=$PR_COUNT"
