#!/usr/bin/env bash
# Multi-agent flow: Linear issue → PR on City-Bureau/documenters.
#
# Five agents (each a fresh `claude -p` invocation, independent context):
#   analyzer    — issue.md          → requirements.json
#   planner     — requirements.json → tasks.json
#   implementer — tasks.json + workdir → commits on a branch
#   validator   — workdir + tasks   → validation.json
#   pr-opener   — full flow state   → pr.json (with PR url)
#
# Communication is filesystem-based. Each agent reads its inputs from files
# and writes outputs to files. No shared context between agents — that's the
# point. The orchestrator routes outputs to the next agent's input.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  flow.sh new <issue.md>            Start a new flow from a Linear issue markdown file
  flow.sh analyze <flow-id>         Run analyzer step
  flow.sh plan <flow-id>            Run planner step
  flow.sh implement <flow-id>       Run implementer for all pending tasks
  flow.sh validate <flow-id>        Run validator step
  flow.sh pr <flow-id>              Run PR opener step
  flow.sh run <issue.md | flow-id>  End-to-end: chain all steps
  flow.sh resume <flow-id>          Continue from the last successful step
  flow.sh status <flow-id>          Show progress for a flow
  flow.sh list                      List all flows
  flow.sh help                      Show this message

Env overrides:
  DEFAULT_MODEL                     claude model for analyzer/planner/validator/pr-opener (default: $DEFAULT_MODEL)
  IMPLEMENTER_MODEL                 claude model for implementer (default: $IMPLEMENTER_MODEL)
  DOCUMENTERS_REPO                  default: $DOCUMENTERS_REPO
  DOCUMENTERS_BASE_BRANCH           default: $DOCUMENTERS_BASE_BRANCH
  MAX_IMPLEMENT_RETRIES             default: $MAX_IMPLEMENT_RETRIES
EOF
}

# ---------- new ----------
cmd_new() {
  local issue_file="$1"
  [ -f "$issue_file" ] || { echo "issue file not found: $issue_file" >&2; exit 1; }

  # Derive a sortable id from the file's first heading or its filename.
  local issue_id
  issue_id=$(grep -m1 -oE '\b[A-Z]{2,5}-[0-9]+\b' "$issue_file" || true)
  if [ -z "$issue_id" ]; then
    issue_id=$(basename "$issue_file" .md)
  fi
  local fid
  fid=$(new_flow_id "$issue_id")
  local d
  d=$(flow_dir "$fid")
  mkdir -p "$d/logs" "$d/validation"
  cp "$issue_file" "$d/issue.md"

  local branch
  branch="claude/${issue_id,,}-$(date +%y%m%d-%H%M)"
  branch=$(echo "$branch" | tr 'A-Z' 'a-z' | sed 's|[^a-z0-9/-]|-|g')

  cat > "$d/state.json" <<EOF
{
  "flow_id": "$fid",
  "issue_id": "$issue_id",
  "issue_file": "$d/issue.md",
  "branch": "$branch",
  "status": "new",
  "steps_completed": [],
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  log "$fid" "Flow created — issue=$issue_id branch=$branch"
  echo "$fid"
}

# ---------- analyze ----------
cmd_analyze() {
  local fid="$1"
  local d
  d=$(flow_dir "$fid")
  log "$fid" "===== analyze ====="
  local out="$d/_analyzer.raw.txt"
  run_agent "$fid" "analyzer" "$d/issue.md" "$out"
  extract_json "$out" "$d/requirements.json"
  state_set "$fid" '.status = "analyzed" | .steps_completed += ["analyze"]'
  log "$fid" "✓ requirements.json"
}

# ---------- plan ----------
cmd_plan() {
  local fid="$1"
  local d
  d=$(flow_dir "$fid")
  log "$fid" "===== plan ====="
  local out="$d/_planner.raw.txt"
  run_agent "$fid" "planner" "$d/requirements.json" "$out"
  extract_json "$out" "$d/tasks.json"
  state_set "$fid" '.status = "planned" | .steps_completed += ["plan"]'
  log "$fid" "✓ tasks.json"
}

# ---------- implement ----------
cmd_implement() {
  local fid="$1"
  local d
  d=$(flow_dir "$fid")
  log "$fid" "===== implement ====="

  ensure_workdir "$fid"
  local wd="$d/workdir"

  local n
  n=$(jq -r '.tasks | length' "$d/tasks.json")
  if [ "$n" -eq 0 ]; then
    log "$fid" "WARN: planner produced 0 tasks — nothing to implement"
    return 0
  fi

  mkdir -p "$d/per_task"

  local i=0
  while [ "$i" -lt "$n" ]; do
    local task_id
    task_id=$(jq -r ".tasks[$i].id" "$d/tasks.json")
    local task_file="$d/per_task/$task_id.input.json"
    jq ".tasks[$i] + {flow_id: \"$fid\", base_branch: \"$DOCUMENTERS_BASE_BRANCH\", workdir: \"$wd\", repo: \"$DOCUMENTERS_REPO\"}" \
      "$d/tasks.json" > "$task_file"

    log "$fid" "task $((i+1))/$n: $task_id"

    local attempt=0
    local out="$d/per_task/$task_id.output.txt"
    while [ "$attempt" -le "$MAX_IMPLEMENT_RETRIES" ]; do
      if run_agent "$fid" "implementer" "$task_file" "$out"; then
        # Implementer is expected to git-commit on the workdir. Verify
        # something changed; if not, treat as a soft failure.
        if [ -n "$(git -C "$wd" log "origin/$DOCUMENTERS_BASE_BRANCH..HEAD" --oneline 2>/dev/null)" ] \
           || [ -n "$(git -C "$wd" status --porcelain 2>/dev/null)" ]; then
          log "$fid" "   ✓ task $task_id implemented (attempt $((attempt+1)))"
          break
        else
          log "$fid" "   ⚠ task $task_id produced no commit/diff — retrying"
        fi
      fi
      attempt=$((attempt+1))
    done
    if [ "$attempt" -gt "$MAX_IMPLEMENT_RETRIES" ]; then
      log "$fid" "   ✗ task $task_id failed after $MAX_IMPLEMENT_RETRIES retries"
      state_set "$fid" ".status = \"failed_at_implement_task_$task_id\""
      return 1
    fi

    i=$((i+1))
  done

  state_set "$fid" '.status = "implemented" | .steps_completed += ["implement"]'
  log "$fid" "✓ all $n tasks implemented"
}

# ---------- validate ----------
cmd_validate() {
  local fid="$1"
  local d
  d=$(flow_dir "$fid")
  log "$fid" "===== validate ====="
  local out="$d/_validator.raw.txt"

  # Bundle context for the validator.
  local input="$d/validator.input.json"
  jq -n \
    --slurpfile req "$d/requirements.json" \
    --slurpfile tasks "$d/tasks.json" \
    --arg workdir "$d/workdir" \
    --arg base "$DOCUMENTERS_BASE_BRANCH" \
    '{requirements: $req[0], tasks: $tasks[0], workdir: $workdir, base_branch: $base}' \
    > "$input"

  run_agent "$fid" "validator" "$input" "$out"
  extract_json "$out" "$d/validation.json"

  local verdict
  verdict=$(jq -r '.verdict' "$d/validation.json")
  if [ "$verdict" != "pass" ]; then
    log "$fid" "✗ validation verdict=$verdict — see $d/validation.json"
    state_set "$fid" '.status = "failed_at_validate"'
    return 1
  fi
  state_set "$fid" '.status = "validated" | .steps_completed += ["validate"]'
  log "$fid" "✓ validation passed"
}

# ---------- pr ----------
cmd_pr() {
  local fid="$1"
  local d
  d=$(flow_dir "$fid")
  log "$fid" "===== open PR ====="

  local wd="$d/workdir"
  local branch
  branch=$(state_get "$fid" '.branch')

  # Push the branch to origin first; the pr-opener will only invoke gh pr create.
  log "$fid" "pushing branch $branch to origin"
  git -C "$wd" push -u origin "$branch" >>"$d/logs/git.log" 2>&1

  local input="$d/pr-opener.input.json"
  jq -n \
    --slurpfile state "$d/state.json" \
    --slurpfile req "$d/requirements.json" \
    --slurpfile tasks "$d/tasks.json" \
    --slurpfile val "$d/validation.json" \
    --arg workdir "$wd" \
    --arg repo "$DOCUMENTERS_REPO" \
    --arg base "$DOCUMENTERS_BASE_BRANCH" \
    --arg branch "$branch" \
    '{state: $state[0], requirements: $req[0], tasks: $tasks[0], validation: $val[0], workdir: $workdir, repo: $repo, base_branch: $base, branch: $branch}' \
    > "$input"

  local out="$d/_pr.raw.txt"
  run_agent "$fid" "pr-opener" "$input" "$out"
  extract_json "$out" "$d/pr.json"

  state_set "$fid" '.status = "pr_opened" | .steps_completed += ["pr"]'
  local url
  url=$(jq -r '.url' "$d/pr.json")
  log "$fid" "✓ PR opened: $url"
  echo "$url"
}

# ---------- run ----------
# SAFETY: by default, cmd_run stops at validate. The pr step pushes a branch
# to a shared remote and opens a PR — that's a shared-state action that
# should be a deliberate human-approved invocation. Pass --auto-pr to chain
# through the pr step (use at your own risk).
cmd_run() {
  local auto_pr="false"
  if [ "${1:-}" = "--auto-pr" ]; then
    auto_pr="true"
    shift
  fi
  local arg="$1"
  local fid
  if [ -f "$arg" ]; then
    fid=$(cmd_new "$arg")
  else
    fid="$arg"
  fi
  cmd_analyze   "$fid" || { log "$fid" "✗ failed at analyze";   return 1; }
  cmd_plan      "$fid" || { log "$fid" "✗ failed at plan";      return 1; }
  cmd_implement "$fid" || { log "$fid" "✗ failed at implement"; return 1; }
  cmd_validate  "$fid" || { log "$fid" "✗ failed at validate";  return 1; }

  if [ "$auto_pr" = "true" ]; then
    cmd_pr "$fid" || { log "$fid" "✗ failed at pr"; return 1; }
  else
    log "$fid" "Stopped before PR step. Review commits under flows/$fid/workdir then run: flow.sh pr $fid"
    echo
    echo "Next: review the implementation and validation, then explicitly:"
    echo "  $0 pr $fid"
  fi
}

# ---------- resume ----------
cmd_resume() {
  local fid="$1"
  local steps
  steps=$(state_get "$fid" '.steps_completed | join(",")')
  case "$steps" in
    "")             cmd_run "$fid" ;;
    "analyze")      cmd_plan "$fid" && cmd_implement "$fid" && cmd_validate "$fid" && cmd_pr "$fid" ;;
    "analyze,plan") cmd_implement "$fid" && cmd_validate "$fid" && cmd_pr "$fid" ;;
    "analyze,plan,implement") cmd_validate "$fid" && cmd_pr "$fid" ;;
    "analyze,plan,implement,validate") cmd_pr "$fid" ;;
    *) echo "Nothing to resume (steps_completed=$steps)" ;;
  esac
}

# ---------- status ----------
cmd_status() {
  local fid="$1"
  jq . "$(flow_dir "$fid")/state.json"
}

# ---------- list ----------
cmd_list() {
  if [ ! -d "$FLOWS_DIR" ]; then return 0; fi
  printf '%-40s %-12s %s\n' "FLOW_ID" "STATUS" "ISSUE"
  for d in "$FLOWS_DIR"/*/; do
    [ -f "$d/state.json" ] || continue
    local fid status issue
    fid=$(basename "$d")
    status=$(jq -r '.status' "$d/state.json")
    issue=$(jq -r '.issue_id' "$d/state.json")
    printf '%-40s %-12s %s\n' "$fid" "$status" "$issue"
  done
}

# ---------- dispatch ----------
main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    new)        cmd_new       "${1:?need issue.md path}" ;;
    analyze)    cmd_analyze   "${1:?need flow-id}" ;;
    plan)       cmd_plan      "${1:?need flow-id}" ;;
    implement)  cmd_implement "${1:?need flow-id}" ;;
    validate)   cmd_validate  "${1:?need flow-id}" ;;
    pr)         cmd_pr        "${1:?need flow-id}" ;;
    run)        cmd_run       "${1:?need issue.md or flow-id}" ;;
    resume)     cmd_resume    "${1:?need flow-id}" ;;
    status)     cmd_status    "${1:?need flow-id}" ;;
    list)       cmd_list ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
