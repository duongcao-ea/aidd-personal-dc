#!/usr/bin/env bash
# Shared helpers for the documenters-issue-to-pr agentic flow.
# Intentionally kept dependency-light: bash 3.2 + jq + gh + claude.

set -u
set -o pipefail

# Resolve repo root from the script location (caller must source via BASH_SOURCE).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
FLOWS_DIR="$REPO_ROOT/flows"

# Defaults — override via env.
DEFAULT_MODEL="${DEFAULT_MODEL:-claude-sonnet-4-6}"
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-claude-opus-4-7}"
DOCUMENTERS_REPO="${DOCUMENTERS_REPO:-City-Bureau/documenters}"
DOCUMENTERS_BASE_BRANCH="${DOCUMENTERS_BASE_BRANCH:-development}"
MAX_IMPLEMENT_RETRIES="${MAX_IMPLEMENT_RETRIES:-2}"

mkdir -p "$FLOWS_DIR"

# Ensure CLI tools resolve under launchd's stripped PATH if invoked headless.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Pull GH PAT from Keychain if not already set. Reuses the entry the PR-review
# agent uses, so a single PAT is enough.
if [ -z "${GH_TOKEN:-}" ]; then
  if GH_TOKEN=$(security find-generic-password -s daily-pr-review-gh-pat -w 2>/dev/null); then
    export GH_TOKEN
  fi
fi

# ----------------------------------------------------------------------
# Flow lifecycle
# ----------------------------------------------------------------------

# new_flow_id: produce a sortable flow id from a Linear issue id + timestamp.
new_flow_id() {
  local issue="$1"
  local slug
  slug=$(echo "$issue" | tr 'A-Z' 'a-z' | sed 's|[^a-z0-9-]|-|g' | sed 's|--*|-|g' | sed 's|^-||;s|-$||')
  echo "$(date +%Y%m%d-%H%M%S)-$slug"
}

# flow_dir <flow-id>
flow_dir() { echo "$FLOWS_DIR/$1"; }

# state_get <flow-id> <jq-path>
state_get() {
  local fid="$1" path="$2"
  jq -r "$path" "$(flow_dir "$fid")/state.json"
}

# state_set <flow-id> <jq-update-expr>
# Example: state_set "$fid" '.status = "analyzed"'
state_set() {
  local fid="$1" expr="$2"
  local f
  f="$(flow_dir "$fid")/state.json"
  local tmp
  tmp=$(mktemp)
  jq "$expr" "$f" > "$tmp" && mv "$tmp" "$f"
}

# log <flow-id> <msg>
log() {
  local fid="$1"; shift
  local d
  d="$(flow_dir "$fid")"
  mkdir -p "$d/logs"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$d/logs/flow.log"
}

# ----------------------------------------------------------------------
# Agent invocation
# ----------------------------------------------------------------------

# run_agent <flow-id> <agent-name> <input-file> <output-file> [extra-prompt]
# Each agent gets a fresh claude session (NOT --resume). Independence is the
# whole point — agents communicate via files, not shared context.
run_agent() {
  local fid="$1" agent="$2" input_file="$3" output_file="$4"
  local extra="${5:-}"
  local d
  d="$(flow_dir "$fid")"

  local prompt_file="$AGENTS_DIR/$agent/prompt.md"
  if [ ! -f "$prompt_file" ]; then
    echo "FATAL: no prompt for agent '$agent' at $prompt_file" >&2
    return 1
  fi

  local tools
  tools=$(awk '/^allowed-tools:/{$1=""; print; exit}' "$prompt_file" | sed 's/^ *//')
  if [ -z "$tools" ]; then
    tools="Read Glob Grep"
  fi

  local model
  model=$(awk '/^model:/{print $2; exit}' "$prompt_file")
  model="${model:-$DEFAULT_MODEL}"

  local sys
  sys=$(awk '/^---$/{c++; next} c==1' "$prompt_file")

  local input
  input=$(cat "$input_file")

  local prompt
  prompt="$sys

# Flow context

- Flow ID: $fid
- Flow dir: $d
- Documenters repo: $DOCUMENTERS_REPO
- Base branch: $DOCUMENTERS_BASE_BRANCH
- Working dir (existing checkout): $d/workdir

# Input

$input
$extra

# Your task

Follow the contract above. Output EXACTLY the JSON / markdown described in the prompt — no preamble, no postscript, no fenced wrapper. The orchestrator will parse it directly."

  local log_file="$d/logs/$agent.log"
  log "$fid" "→ agent $agent (model=$model, tools=[$tools])"
  log "$fid" "   input: $input_file"

  if claude -p "$prompt" \
       --allowed-tools "$tools" \
       --output-format text \
       --model "$model" \
       --no-session-persistence \
       --add-dir "$d" \
       > "$output_file" 2>>"$log_file"; then
    log "$fid" "   ✓ $output_file"
    return 0
  else
    log "$fid" "   ✗ agent $agent failed (see $log_file)"
    return 1
  fi
}

# extract_json <input-file> <output-file>
# Strip any accidental fence wrappers / preamble around a JSON object.
extract_json() {
  local in="$1" out="$2"
  python3 - "$in" "$out" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", src, re.DOTALL)
if m:
    src = m.group(1)
else:
    s = src.find("{")
    e = src.rfind("}")
    if s >= 0 and e > s:
        src = src[s : e + 1]
data = json.loads(src)
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2)
PY
}

# ----------------------------------------------------------------------
# Workdir management
# ----------------------------------------------------------------------

# ensure_workdir <flow-id>
# Clone the documenters repo into the flow's workdir and check out a fresh
# branch off the base branch. Idempotent: re-uses existing checkout if branch
# is already created and points at expected base.
ensure_workdir() {
  local fid="$1"
  local d
  d="$(flow_dir "$fid")"
  local wd="$d/workdir"
  local branch
  branch=$(state_get "$fid" '.branch')

  if [ -d "$wd/.git" ]; then
    log "$fid" "workdir exists at $wd, fetching latest base"
    git -C "$wd" fetch origin "$DOCUMENTERS_BASE_BRANCH" >>"$d/logs/git.log" 2>&1
    if ! git -C "$wd" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$wd" checkout -b "$branch" "origin/$DOCUMENTERS_BASE_BRANCH" >>"$d/logs/git.log" 2>&1
    else
      git -C "$wd" checkout "$branch" >>"$d/logs/git.log" 2>&1
    fi
    return 0
  fi

  log "$fid" "cloning $DOCUMENTERS_REPO into $wd"
  mkdir -p "$d/logs"
  gh repo clone "$DOCUMENTERS_REPO" "$wd" -- \
    --branch "$DOCUMENTERS_BASE_BRANCH" --depth 50 \
    >>"$d/logs/git.log" 2>&1
  git -C "$wd" checkout -b "$branch" >>"$d/logs/git.log" 2>&1
  git -C "$wd" config user.name "duongcao-ea"
  git -C "$wd" config user.email "duong.cao@eastagile.com"
}
