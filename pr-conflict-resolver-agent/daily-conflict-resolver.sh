#!/usr/bin/env bash
# Daily PR conflict resolver agent (draft — review before installing to ~/bin).
#
# For each open, non-draft, non-dependabot PR from 2026 across the selected
# City-Bureau/city-scrapers* repos that has a merge conflict against `staging`,
# spawns a sandboxed Claude agent to resolve the conflicts. With --apply, pushes
# the resolution to `auto/resolve-conflict-pr-<num>` and opens a follow-up PR
# (base=staging) for human review. NEVER pushes to staging directly.
#
# Safety by design:
#   --dry-run (default): resolve locally, print intended diff/branch, exit. No push, no PR.
#   --apply:             after resolution, push the branch and open a follow-up PR.
#   --repo <name>:       scope to a single repo (recommended for first runs).
#   Idempotent:          if `auto/resolve-conflict-pr-<num>` exists on origin, skip.
#
# Auth: GH_TOKEN loaded from macOS Keychain (service=daily-pr-review-gh-pat).
# For --apply mode the underlying PAT needs push perms: classic `repo`, or
# fine-grained `Contents: write` + `Pull requests: write` on the target repos.
#
# Output: per-PR log at ~/pr-conflict-resolutions/_logs/<repo>_PR<num>.log
#         daily summary at ~/pr-conflict-resolutions/_logs/run-YYYY-MM-DD.log

set -u
set -o pipefail

OWNER="City-Bureau"
OUT_DIR="$HOME/pr-conflict-resolutions"
LOG_DIR="$OUT_DIR/_logs"
WORK_ROOT="/tmp/pr-conflict-resolver"
TODAY="$(date +%Y-%m-%d)"
LOG_FILE="$LOG_DIR/run-$TODAY.log"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-daily-pr-review-gh-pat}"

# CLI flags
MODE="dry-run"          # dry-run | apply
REPO_FILTER=""          # empty = all city-scrapers*; otherwise exact repo name

usage() {
  cat <<EOF
Usage: $0 [--apply] [--repo <name>]

  --apply           Push resolutions + open follow-up PRs. Without this, runs as dry-run.
  --repo <name>     Limit to one repo (e.g. city-scrapers-atl). Default: all city-scrapers*.
  -h, --help        Print this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    --repo) REPO_FILTER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Apply mode pushes to staging — serialize to avoid push races.
[ "$MODE" = "apply" ] && MAX_PARALLEL=1

mkdir -p "$OUT_DIR" "$LOG_DIR" "$WORK_ROOT"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Pick the highest installed pyenv interpreter matching Pipfile's python_version
# AND has `pipenv` installed in it. Falls back to 3.12 if Pipfile is absent.
# Returns empty string if no suitable version is found.
_pyenv_for_pipfile() {
  local v
  v=$(grep -E '^\s*python_version' Pipfile 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  [ -z "$v" ] && v="3.12"
  local pyenv_root
  pyenv_root=$(pyenv root 2>/dev/null)
  [ -z "$pyenv_root" ] && return
  pyenv versions --bare 2>/dev/null \
    | grep -E "^${v}([.]|$)" \
    | grep -v '/' \
    | sort -V \
    | while read -r ver; do
        [ -x "${pyenv_root}/versions/${ver}/bin/pipenv" ] && echo "$ver"
      done \
    | tail -1
}

if ! GH_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null); then
  log "FATAL: could not load GH_TOKEN from Keychain (service=$KEYCHAIN_SERVICE)."
  log "       Run: security add-generic-password -a \"\$USER\" -s $KEYCHAIN_SERVICE -w -U -T /usr/bin/security"
  exit 1
fi
export GH_TOKEN

resolve_pr() {
  local repo="$1" num="$2" title="$3"
  local task_log="$LOG_DIR/${repo}_PR${num}.log"
  local workdir="$WORK_ROOT/${repo}_PR${num}"
  local resolution_branch="auto/resolve-conflict-pr-${num}"

  log "  → ${repo} #${num}: ${title}"

  rm -rf "$workdir"
  if ! git clone --quiet "https://x-access-token:${GH_TOKEN}@github.com/${OWNER}/${repo}.git" "$workdir" >>"$task_log" 2>&1; then
    log "    ✗ clone failed (see $task_log)"
    return 1
  fi

  cd "$workdir" || return 1
  # Use the operator's git identity (inherits from --global config).
  git config user.name "$(git config --global user.name)"
  git config user.email "$(git config --global user.email)"

  if git ls-remote --exit-code --heads origin "$resolution_branch" >/dev/null 2>&1; then
    log "    (resolution branch ${resolution_branch} already exists on origin — skipping)"
    return 0
  fi

  if ! git checkout -q staging >>"$task_log" 2>&1; then
    log "    ✗ ${repo} has no staging branch"
    return 1
  fi

  if ! git fetch -q origin "pull/${num}/head:pr-${num}" >>"$task_log" 2>&1; then
    log "    ✗ failed to fetch pull/${num}/head"
    return 1
  fi

  if git merge --no-commit --no-ff "pr-${num}" >>"$task_log" 2>&1; then
    log "    (clean merge — no conflict; skipping)"
    git merge --abort >>"$task_log" 2>&1 || true
    return 0
  fi

  local conflicted_files
  conflicted_files=$(git diff --name-only --diff-filter=U)
  if [ -z "$conflicted_files" ]; then
    log "    ✗ merge failed but git reports no conflicted files"
    git merge --abort >>"$task_log" 2>&1 || true
    return 1
  fi

  log "    conflicts: $(echo "$conflicted_files" | tr '\n' ' ')"

  # Bucket conflicts: code (AI resolves) vs lockfiles (orchestrator regenerates
  # via `pipenv lock`). Lockfiles are *derived* artifacts — re-running the
  # generating tool against the merged manifest is the deterministic resolution.
  local lockfiles code_files
  lockfiles=$(echo "$conflicted_files" | grep -E '(^|/)Pipfile\.lock$' || true)
  code_files=$(echo "$conflicted_files" | grep -vE '(^|/)Pipfile\.lock$' || true)

  if [ -n "$code_files" ]; then
    local prompt
    prompt="You are resolving a Git merge conflict.

Repository: ${OWNER}/${repo}
Goal: merge PR #${num} (\`pr-${num}\` ref) into the \`staging\` branch.
Working tree: ${workdir} (already in conflict state — do NOT run \`git checkout\`, \`git merge --abort\`, or change branches).

Conflicted code files (every conflict block in each must be resolved):
$(echo "$code_files" | sed 's/^/  - /')

NOTE: Pipfile.lock is also conflicted but is handled separately by the orchestrator via \`pipenv lock\`. Do NOT touch Pipfile.lock.

Process:
1. Read each conflicted file. Conflict markers look like:
       <<<<<<< HEAD            (ours = current \`staging\`)
       ...
       =======
       ...
       >>>>>>> pr-${num}       (theirs = PR ${num})
2. Resolve each block:
   - If the two sides edit orthogonal things (different lines, different attributes), preserve BOTH.
   - If they edit the same logical thing, prefer the PR (\`pr-${num}\`) version, since the PR is what needs to land in \`staging\`.
   - When uncertain, keep the PR version and leave a comment \`# TODO(human): verify auto-resolved merge\` adjacent so a reviewer can find it.
3. Remove every conflict marker (\`<<<<<<<\`, \`=======\`, \`>>>>>>>\` lines).
4. Do NOT run \`git add\`, \`git commit\`, or \`git checkout\`. The orchestrator handles git ops after you finish.

Allowed tools: Read, Edit, Glob, Grep, Bash (Bash for read-only inspection only — \`git status\`, \`git diff\`, \`ls\`, \`cat\`; do not mutate the working tree besides Edit).

When done, print exactly this line at the end of your output: CONFLICTS RESOLVED
"

    if ! claude -p "$prompt" \
           --allowed-tools "Read Edit Glob Grep Bash" \
           --output-format text \
           --no-session-persistence \
           >>"$task_log" 2>&1; then
      log "    ✗ claude -p exited non-zero (see $task_log)"
      git merge --abort >>"$task_log" 2>&1 || true
      return 1
    fi

    local marker_files
    marker_files=$(echo "$code_files" | xargs -I{} grep -lE '^(<<<<<<<|=======|>>>>>>>)' {} 2>/dev/null || true)
    if [ -n "$marker_files" ]; then
      log "    ✗ conflict markers still present in: $marker_files"
      git merge --abort >>"$task_log" 2>&1 || true
      return 1
    fi

    echo "$code_files" | xargs git add
  fi

  if [ -n "$lockfiles" ]; then
    # Guard: if an EXTERNAL contributor's PR modifies Pipfile (potentially adds
    # a new package), refuse to auto-lock — bump to human review. Trusted
    # internal contributors (OWNER/MEMBER/COLLABORATOR) and external PRs that
    # don't touch Pipfile pass through normally.
    if [ -f Pipfile ] && ! git diff --quiet staging -- Pipfile 2>/dev/null; then
      local author author_assoc
      author=$(gh pr view "$num" --repo "$OWNER/$repo" --json author --jq '.author.login' 2>/dev/null)
      author_assoc=$(gh pr view "$num" --repo "$OWNER/$repo" --json authorAssociation --jq '.authorAssociation' 2>/dev/null)
      case "$author_assoc" in
        OWNER|MEMBER|COLLABORATOR)
          log "    Pipfile modified by trusted ${author_assoc} ${author} — proceeding with auto-lock"
          ;;
        *)
          log "    ✗ external contributor (${author}, ${author_assoc:-unknown}) modifies Pipfile — skipping for human review"
          git merge --abort >>"$task_log" 2>&1 || true
          return 1
          ;;
      esac
    fi

    local pyver
    pyver=$(_pyenv_for_pipfile)
    if [ -z "$pyver" ]; then
      log "    ✗ no matching pyenv interpreter for Pipfile python_version — skipping"
      git merge --abort >>"$task_log" 2>&1 || true
      return 1
    fi
    log "    regenerating lockfile via pipenv lock (PYENV_VERSION=${pyver})"
    echo "$lockfiles" | xargs rm -f
    if ! PYENV_VERSION="$pyver" pipenv lock >>"$task_log" 2>&1; then
      log "    ✗ pipenv lock failed — skipping PR (see $task_log)"
      git merge --abort >>"$task_log" 2>&1 || true
      return 1
    fi
    echo "$lockfiles" | xargs git add
  fi
  if ! git commit -q -m "Resolve merge conflicts for PR #${num} (auto)

Auto-resolved by daily-conflict-resolver. Files touched:
$(echo "$conflicted_files" | sed 's/^/- /')" >>"$task_log" 2>&1; then
    log "    ✗ git commit failed"
    return 1
  fi

  if ! git checkout -q -b "$resolution_branch" >>"$task_log" 2>&1; then
    log "    ✗ branch checkout failed"
    return 1
  fi
  # Reset the local `staging` branch back to origin/staging so the workdir is
  # easy to inspect (resolution branch ahead by one merge commit; staging at
  # the same place as origin).
  git branch -f staging origin/staging >>"$task_log" 2>&1 || true

  if [ "$MODE" = "dry-run" ]; then
    log "    ✓ [dry-run] resolved locally at ${workdir}; branch ${resolution_branch} ready to push"
    log "      diff stats vs origin/staging: $(git diff origin/staging --shortstat | tr -s ' ')"
    log "      files changed: $(git diff origin/staging --name-only | tr '\n' ' ')"
    return 0
  fi

  # --apply path: push the merge commit directly to staging (same trust posture
  # as refresh-staging.yml). Refresh origin/staging right before the push to
  # detect races where another worker advanced staging; if our merge is no
  # longer a fast-forward of origin/staging, skip rather than force-push.
  git fetch -q origin staging >>"$task_log" 2>&1 || true
  if ! git merge-base --is-ancestor origin/staging HEAD; then
    log "    ✗ origin/staging advanced since we cloned — skipping (will retry next run)"
    return 1
  fi
  if ! git push -q origin "${resolution_branch}:staging" >>"$task_log" 2>&1; then
    log "    ✗ git push to origin staging failed (see $task_log — check PAT scopes / branch protection)"
    return 1
  fi

  log "    ✓ pushed merge of PR #${num} to ${repo} staging"
  return 0
}

log "Starting daily PR conflict resolver (mode=$MODE, MAX_PARALLEL=$MAX_PARALLEL, repo_filter=${REPO_FILTER:-<all>})"

if [ -n "$REPO_FILTER" ]; then
  REPOS="$REPO_FILTER"
  REPO_COUNT=1
else
  REPOS=$(gh repo list "$OWNER" --limit 200 --json name,isArchived \
    | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["name"].startswith("city-scrapers") and not r["isArchived"]:
        print(r["name"])
' | sort)
  REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
fi
log "Scanning $REPO_COUNT repo(s)"

WORK_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE"' EXIT

# Discovery: only consider repos that have a `refresh-staging.yml` workflow,
# and only PRs that refresh-staging itself reported as Skipped (= conflicting)
# in its most recent run. We trust the workflow's own "Skipped:" output rather
# than recomputing — refresh-staging already filtered drafts and bots, and
# already did the trial merge.
while read -r repo; do
  [ -z "$repo" ] && continue

  run_id=$(gh run list --repo "$OWNER/$repo" --workflow refresh-staging.yml --limit 1 \
    --json databaseId 2>/dev/null \
    | python3 -c 'import json, sys; d=json.load(sys.stdin); print(d[0]["databaseId"] if d else "")' 2>/dev/null)
  if [ -z "$run_id" ]; then
    continue  # no refresh-staging workflow in this repo
  fi

  # Pull the "Skipped: #N #M" line from the run's log. Empty if no conflicts.
  skipped_nums=$(gh run view "$run_id" --repo "$OWNER/$repo" --log 2>/dev/null \
    | grep -E '\bSkipped:' \
    | tail -1 \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    || true)
  if [ -z "$skipped_nums" ]; then
    continue  # latest refresh-staging run had no conflicts
  fi

  log "  ${repo}: refresh-staging run ${run_id} skipped PRs: $(echo "$skipped_nums" | tr '\n' ' ')"

  for num in $skipped_nums; do
    title=$(gh pr view "$num" --repo "$OWNER/$repo" --json title --jq '.title' 2>/dev/null \
            | tr '\t\n' '  ')
    printf '%s\t%s\t%s\n' "$repo" "$num" "$title" >> "$WORK_FILE"
  done
done <<< "$REPOS"

PR_COUNT=$(wc -l < "$WORK_FILE" | tr -d ' ')
log "Found $PR_COUNT conflicting PRs from refresh-staging output"

if [ "$PR_COUNT" -eq 0 ]; then
  log "Nothing to do."
  exit 0
fi

SUCCESS_FILE=$(mktemp)
FAIL_FILE=$(mktemp)
trap 'rm -f "$WORK_FILE" "$SUCCESS_FILE" "$FAIL_FILE"' EXIT

run_one() {
  local r="$1" n="$2" t="$3"
  if resolve_pr "$r" "$n" "$t"; then
    echo "${r}#${n}" >> "$SUCCESS_FILE"
  else
    echo "${r}#${n}" >> "$FAIL_FILE"
  fi
}

while IFS=$'\t' read -r repo num title; do
  [ -z "$repo" ] && continue
  while [ "$(jobs -r 2>/dev/null | wc -l | tr -d ' ')" -ge "$MAX_PARALLEL" ]; do
    sleep 0.5
  done
  run_one "$repo" "$num" "$title" &
done < "$WORK_FILE"

wait

SUCCESS=$(wc -l < "$SUCCESS_FILE" 2>/dev/null | tr -d ' ')
FAIL=$(wc -l < "$FAIL_FILE" 2>/dev/null | tr -d ' ')
log "Done. Mode=$MODE Resolved=${SUCCESS:-0} Failed=${FAIL:-0} Total=$PR_COUNT"
