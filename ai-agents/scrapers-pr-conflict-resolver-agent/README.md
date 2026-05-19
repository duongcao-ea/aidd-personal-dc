# scrapers-pr-conflict-resolver-agent

A scheduled AI agent that resolves merge conflicts for
`City-Bureau/city-scrapers*` pull requests that the `refresh-staging.yml`
workflow skipped because they conflict against `staging`.

## Overview

Each day at 09:00 local time — after `refresh-staging` (03:00) and the
[`scrapers-pr-review-agent`](../scrapers-pr-review-agent) (08:00) —
`launchd` runs
[`bin/daily-conflict-resolver.sh --apply`](./bin/daily-conflict-resolver.sh),
which:

1. Scans every active `City-Bureau/city-scrapers*` repository for a
   `refresh-staging.yml` workflow.
2. Reads the latest workflow run's `Skipped: #N #M` line — the PRs
   `refresh-staging` itself reported as conflicting.
3. For each skipped PR:
   - Clones a fresh copy under
     `/tmp/pr-conflict-resolver/<repo>_PR<number>/`.
   - Trial-merges `pr-<number>` into `staging`.
   - **Code conflicts** are handed to a sandboxed `claude -p`
     (Read/Edit/Glob/Grep plus read-only Bash). The prompt prefers the PR
     side on overlapping changes and asks the agent to leave
     `# TODO(human): verify auto-resolved merge` markers where it was
     uncertain.
   - **`Pipfile.lock` conflicts** bypass the AI and are resolved by running
     `pipenv lock` against the merged `Pipfile` — a deterministic tool for
     a deterministic problem.
   - **External-contributor `Pipfile` changes** (author association not in
     `{OWNER, MEMBER, COLLABORATOR}`) are refused and escalated to manual
     review rather than auto-locked.
4. Pushes the merge commit directly to `origin staging`, guarded so the
   push is refused unless it is a fast-forward of `origin/staging`.
5. Runs serially in `--apply` mode (`MAX_PARALLEL=1`) so concurrent pushes
   to `staging` cannot race.

Commits are made under the global git identity — no `github-actions[bot]`
and no co-author trailer.

## Directory layout

```
scrapers-pr-conflict-resolver-agent/
├── README.md
├── bin/
│   └── daily-conflict-resolver.sh                  # Orchestrator (install to ~/bin/)
├── launchd/
│   └── com.duongcao.daily-conflict-resolver.plist  # Schedule (install to ~/Library/LaunchAgents/)
└── samples/
    └── run-2026-05-14.log                          # First production run: city-scrapers-atl, PRs #205 & #207
```

## Prerequisites

- `claude` CLI, authenticated.
- `gh` CLI, authenticated as `duongcao-ea`.
- `pipenv` available via `pyenv` (the script auto-selects the highest
  `pyenv` interpreter that has `pipenv` and matches the `Pipfile`
  `python_version`).
- A macOS Keychain entry `daily-pr-review-gh-pat` holding a GitHub PAT with
  push permission (`Contents: write` + `Pull requests: write`, or classic
  `repo`). This is the same entry used by the pr-review-agent.
- macOS — the launchd plist paths are hard-coded for `/Users/duongcaochanh/`.

## Installation

```bash
cp bin/daily-conflict-resolver.sh ~/bin/daily-conflict-resolver.sh
chmod +x ~/bin/daily-conflict-resolver.sh
cp launchd/com.duongcao.daily-conflict-resolver.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.duongcao.daily-conflict-resolver.plist
```

## Manual run

```bash
# Dry run (default): resolve locally, log intended changes, no push.
bash ~/bin/daily-conflict-resolver.sh
bash ~/bin/daily-conflict-resolver.sh --repo city-scrapers-atl

# Apply: push merge commits directly to staging (serialized).
bash ~/bin/daily-conflict-resolver.sh --apply
bash ~/bin/daily-conflict-resolver.sh --repo city-scrapers-atl --apply
```

## Logs

- Orchestrator: `~/pr-conflict-resolutions/_logs/run-<date>.log`
- Per-PR Claude transcript and git output:
  `~/pr-conflict-resolutions/_logs/<repo>_PR<number>.log`

## Safety properties

- **Fast-forward only.** A push to `staging` is refused unless the merge is
  a fast-forward of `origin/staging`; a race condition causes a skip and
  retry on the next run.
- **Idempotent.** After a successful resolution the PR no longer appears in
  `refresh-staging`'s `Skipped:` list, so a subsequent run pushes nothing.
- **No conflict markers are ever committed.** A sanity check runs after AI
  resolution.
- **External-contributor `Pipfile` changes go to human review,** bounding
  the trust escalation of running `pipenv lock` on PRs from the public
  internet.
- **Recoverable.** If a resolution is wrong, `git revert <merge-sha>` on
  `staging` and re-trigger `refresh-staging.yml`.

## Design decisions

- **Parse `refresh-staging`'s `Skipped:` line rather than re-trial-merging
  every PR.** `refresh-staging` already attempted the merge and filtered out
  drafts and bots; redoing that work is wasteful and reaches different
  conclusions when timing differs (GitHub's asynchronous `mergeable` field
  reflects PR-vs-base, not PR-vs-staging).
- **Run `pipenv lock` instead of letting the AI edit `Pipfile.lock`.**
  Lockfiles are derived artifacts; the correct resolution is to rerun the
  generating tool against the merged manifest. Earlier attempts at AI-edited
  lockfiles silently dropped one side's transitive dependencies.
- **Push to `staging` directly rather than opening a follow-up PR.** This
  matches the trust posture of `refresh-staging.yml`, which also pushes
  `staging` unattended; a follow-up PR adds a click nobody makes.
- **Serialize pushes (`MAX_PARALLEL=1`) in apply mode.** Parallel workers on
  the same `staging` branch produce non-fast-forward pushes that are
  rejected; serial execution is simpler than fetch-rebase-retry loops.

See [`../../docs/agent-operations.md`](../../docs/agent-operations.md) for
conventions shared with the other agents.
