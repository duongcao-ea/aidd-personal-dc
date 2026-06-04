#!/usr/bin/env bash
# Daily PR review routine for City-Bureau/documenters.
# Lists open PRs from the current year that duongcao-ea has not approved
# yet (excluding bots), then runs the /code-review skill on each in parallel
# via headless `claude -p`. Writes one markdown file per PR to
# ~/pr-reviews/documenters_PR<num>.md (overwritten daily).

set -u
set -o pipefail

OWNER="City-Bureau"
REPO="documenters"
ME="duongcao-ea"
OUT_DIR="$HOME/pr-reviews"
LOG_DIR="$HOME/pr-reviews/_logs"
TODAY="$(date +%Y-%m-%d)"
LOG_FILE="$LOG_DIR/run-documenters-$TODAY.log"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
YEAR="$(date +%Y)"

mkdir -p "$OUT_DIR" "$LOG_DIR"

# Ensure CLI tools resolve under launchd's stripped PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Load GH PAT from macOS Keychain. Reuses the same Keychain entry the
# scrapers agent uses — single PAT works for the whole org.
if ! GH_TOKEN=$(security find-generic-password -s daily-pr-review-gh-pat -w 2>/dev/null); then
  log "FATAL: could not load GH_TOKEN from Keychain (service=daily-pr-review-gh-pat). Run: security add-generic-password -a \"\$USER\" -s daily-pr-review-gh-pat -w -U -T /usr/bin/security"
  exit 1
fi
export GH_TOKEN

# Review one PR. Args: num title
review_pr() {
  local num="$1"
  local title="$2"
  local out_file="$OUT_DIR/${REPO}_PR${num}.md"
  local task_log="$LOG_DIR/${REPO}_PR${num}.log"

  log "  → ${REPO} #${num}: ${title}"

  local diff
  diff=$(gh pr diff "$num" --repo "$OWNER/$REPO" 2>>"$task_log") || diff=""
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
  pr_meta=$(gh pr view "$num" --repo "$OWNER/$REPO" \
    --json title,body,author,baseRefName,headRefName,url 2>>"$task_log") || pr_meta="{}"

  local prompt
  prompt="Run the /code-review skill on this pull request and output the review as markdown.

Repo: $OWNER/$REPO
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

log "Starting daily documenters PR review (MAX_PARALLEL=$MAX_PARALLEL)"

# 1. Collect open PRs from the current year, excluding bots and already-approved.
WORK_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE"' EXIT

gh pr list --repo "$OWNER/$REPO" --state open \
  --search "created:${YEAR}-01-01..${YEAR}-12-31 -author:app/dependabot -author:app/renovate" \
  --json number,title,author,reviews,isDraft 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
me = '$ME'
bots = {
    'app/dependabot', 'dependabot[bot]', 'dependabot',
    'app/renovate', 'renovate[bot]', 'renovate',
    'coderabbitai', 'coderabbitai[bot]',
    'github-actions', 'github-actions[bot]',
}
for pr in data:
    if pr.get('isDraft'):
        continue
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
    title = (pr.get('title') or '').replace('\t', ' ').replace('\n', ' ')
    print(f\"{pr['number']}\t{title}\")
" >> "$WORK_FILE" || true

PR_COUNT=$(wc -l < "$WORK_FILE" | tr -d ' ')
log "Found $PR_COUNT PRs to review"

if [ "$PR_COUNT" -eq 0 ]; then
  log "Nothing to do."
  exit 0
fi

# 2. Process in parallel with a concurrency cap.
SUCCESS_FILE=$(mktemp)
FAIL_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE" "$SUCCESS_FILE" "$FAIL_FILE"' EXIT

run_one() {
  local n="$1" t="$2"
  if review_pr "$n" "$t"; then
    echo "${REPO}#${n}" >> "$SUCCESS_FILE"
  else
    echo "${REPO}#${n}" >> "$FAIL_FILE"
  fi
}

while IFS=$'\t' read -r num title; do
  [ -z "$num" ] && continue
  # Throttle: wait while running job count >= MAX_PARALLEL
  while [ "$(jobs -r 2>/dev/null | wc -l | tr -d ' ')" -ge "$MAX_PARALLEL" ]; do
    sleep 0.5
  done
  run_one "$num" "$title" </dev/null &
done < "$WORK_FILE"

wait

SUCCESS=$(wc -l < "$SUCCESS_FILE" 2>/dev/null | tr -d ' ')
FAIL=$(wc -l < "$FAIL_FILE" 2>/dev/null | tr -d ' ')
log "Done. Reviewed=${SUCCESS:-0} Failed=${FAIL:-0} Total=$PR_COUNT"
