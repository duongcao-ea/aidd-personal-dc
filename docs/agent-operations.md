# Agent operations

Conventions shared by every agent under [`../ai-agents/`](../ai-agents/).
Agent-specific behaviour, installation, and flags are documented in each
agent's own `README.md`; this guide covers only what is common.

## Platform

- **macOS only.** Agents are scheduled with `launchd`. The supplied plist
  files use paths hard-coded to `/Users/duongcaochanh/`; adjust them for a
  different home directory before installing.
- Each agent ships an executable wrapper under `bin/` and its schedule
  under `launchd/`. Installation copies `bin/<script>.sh` to `~/bin/` and
  the plist to `~/Library/LaunchAgents/`.

## Credentials

- **GitHub PAT in the Keychain.** Both agents read the token from the
  macOS Keychain entry `daily-pr-review-gh-pat` via
  `security find-generic-password`. The token needs push permission:
  fine-grained `Contents: write` + `Pull requests: write`, or the classic
  `repo` scope. The two agents share this single entry.
- The `claude` and `gh` CLIs must be authenticated independently; see each
  agent's prerequisites.

## Logs

Each agent writes to a `_logs/` directory beneath its output directory in
`$HOME`:

| Agent | Log location |
|---|---|
| scrapers-pr-review-agent | `~/pr-reviews/_logs/` |
| scrapers-pr-conflict-resolver-agent | `~/pr-conflict-resolutions/_logs/` |

Every run produces a `run-<date>.log` orchestrator log plus one
`<repo>_PR<number>.log` per processed PR.

## Daily schedule

The agents run in a deliberate order so each builds on the previous one's
output:

| Time | Job | Role |
|---|---|---|
| 03:00 | `refresh-staging.yml` (upstream CI) | Produces the conflict signal — the `Skipped:` list. |
| 08:00 | scrapers-pr-review-agent | Reviews every open non-draft, non-dependabot PR. |
| 09:00 | scrapers-pr-conflict-resolver-agent | Closes the loop: gets conflict-blocked PRs back into `staging`. |

Running review before conflict-resolution keeps human attention on PR
quality first, then lets automation clear the mechanical merge backlog.
