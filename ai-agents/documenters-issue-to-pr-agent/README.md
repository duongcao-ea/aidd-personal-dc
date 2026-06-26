# documenters-issue-to-pr-agent

A multi-agent flow that turns a Linear issue into a PR on `City-Bureau/documenters`. Each agent is a fresh `claude -p` invocation with its own context — they communicate via JSON files in a per-flow directory, not via shared state.

```
┌──────────────┐    ┌─────────┐    ┌─────────────┐    ┌───────────┐    ┌────────────┐
│   issue.md   │ →  │ analyzer│ →  │   planner   │ →  │implementer│ →  │  validator │ → [STOP — human review]
│ (Linear copy)│    │ Sonnet  │    │   Sonnet    │    │   Opus    │    │   Sonnet   │
└──────────────┘    └─────────┘    └─────────────┘    └───────────┘    └────────────┘
                         ↓               ↓                ↓                ↓
                  requirements.json  tasks.json        commits         validation.json
                                                                              ↓
                                                                      (manual) flow.sh pr <id>
                                                                              ↓
                                                                       ┌────────────┐
                                                                       │ pr-opener  │ → PR url
                                                                       └────────────┘
```

## Safety model

The orchestrator **stops by default at validate**. Pushing a branch + opening a PR is a shared-state action and should be an explicit, human-approved step. After validate, you review the local commits + the validator's report, then run `flow.sh pr <flow-id>` to push and open.

You can override with `flow.sh run --auto-pr <issue.md>` to chain through — **use at your own risk**, ideally only after running through several flows manually.

## Quick start

```bash
# 1. Save the Linear issue body as markdown. Include the issue id (e.g. DOC-1234)
#    in the first line; the orchestrator picks it up via regex.
cat > /tmp/doc-1234.md <<EOF
DOC-1234: Title

Description...

Acceptance criteria:
- ...
- ...
EOF

# 2. Start a new flow. Returns the flow id.
fid=$(./bin/flow.sh new /tmp/doc-1234.md)
echo "Flow: $fid"

# 3. Run end-to-end through validate (stops before PR).
./bin/flow.sh run "$fid"

# 4. Review commits + validation locally.
cd flows/$fid/workdir
git log --oneline origin/development..HEAD
cat ../validation.json

# 5. If happy, open the PR explicitly.
cd -
./bin/flow.sh pr "$fid"
```

## Per-step commands

```
flow.sh new <issue.md>            Create a new flow, returns flow-id
flow.sh analyze <flow-id>         Read issue, produce requirements.json
flow.sh plan <flow-id>            Decompose into tasks.json
flow.sh implement <flow-id>       Run implementer per task (commits on a branch in workdir)
flow.sh validate <flow-id>        Run tests + lint + acceptance check → validation.json
flow.sh pr <flow-id>              Push branch + open PR  ← requires human approval per safety model
flow.sh run [--auto-pr] <id|md>   Chain steps. Stops at validate unless --auto-pr.
flow.sh resume <flow-id>          Continue from the last successful step
flow.sh status <flow-id>          jq dump of the flow's state.json
flow.sh list                      All known flows
```

## Layout

```
documenters-issue-to-pr-agent/
├── README.md
├── bin/
│   ├── flow.sh        # orchestrator (state machine + dispatch)
│   └── lib.sh         # shared helpers + agent invocation
├── agents/
│   ├── analyzer/prompt.md     # role + output schema for each agent
│   ├── planner/prompt.md
│   ├── implementer/prompt.md
│   ├── validator/prompt.md
│   └── pr-opener/prompt.md
└── flows/             # per-flow state — gitignored
    └── <flow-id>/
        ├── state.json          # high-level: id, branch, status, steps_completed
        ├── issue.md            # input
        ├── requirements.json   # analyzer output
        ├── tasks.json          # planner output
        ├── per_task/           # implementer inputs + outputs per task
        ├── workdir/            # git clone of documenters at the feature branch
        ├── validation.json     # validator output
        ├── pr.json             # pr-opener output (only after manual `flow.sh pr`)
        └── logs/               # per-agent stdout/stderr
```

## Configuration

Env vars (all optional):

| Var | Default | Purpose |
|---|---|---|
| `DEFAULT_MODEL` | `claude-sonnet-4-6` | Analyzer / planner / validator / pr-opener model |
| `IMPLEMENTER_MODEL` | `claude-opus-4-7` | Implementer model (bumped for code-writing accuracy) |
| `DOCUMENTERS_REPO` | `City-Bureau/documenters` | gh repo to PR against |
| `DOCUMENTERS_BASE_BRANCH` | `development` | PR base |
| `MAX_IMPLEMENT_RETRIES` | `2` | Per-task retry budget on empty-diff outcome |
| `GH_TOKEN` | from Keychain `daily-pr-review-gh-pat` | GitHub PAT |

## Why each agent has its own session

If one Claude session did everything, the implementer would inherit the analyzer's biases ("I already said complexity=small so let me cut corners"). Independent sessions = each agent re-derives its view from the JSON contract its predecessor produced. The contract is the protocol.

That also means **debugging** is just reading the JSON files. No "what was Claude thinking?" — the trail is on disk.

## Common gotchas

- **Empty diff after implement** — usually the implementer mis-read `files_to_modify` and edited the wrong path. Check `flows/<id>/per_task/<task>.output.txt` for the agent's notes.
- **Validator says `fail`** — read `validation.json` blockers. Rerun `flow.sh implement <id>` after fixing the plan, or hand-edit in `workdir/`.
- **Need to start over** — `rm -rf flows/<flow-id>` and `flow.sh new` again. State is fully derivable from `issue.md`.
- **PR step refuses to run** — validator verdict isn't `pass`. Either fix the issues (re-implement) or set `verdict: pass` manually in `validation.json` if you've already verified out-of-band (don't lie to yourself — that defeats the validator's purpose).

## What this is NOT

- **Not a CI replacement.** Run actual CI on the PR after opening — the validator only runs scoped tests + lint on the diff.
- **Not a security review.** The implementer can write SQL-injection-shaped code if the analyzer/planner don't flag it. Wire your usual security checks into the PR's required-status-checks.
- **Not for prod-DB-touching tasks.** Migrations are OK; running them against prod is not. The agent will write the migration; humans deploy.
