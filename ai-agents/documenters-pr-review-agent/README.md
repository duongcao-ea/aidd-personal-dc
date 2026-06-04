# documenters-pr-review-agent

A scheduled, headless AI code-review agent for open pull requests on
`City-Bureau/documenters`. Mirrors the `scrapers-pr-review-agent` pattern but
scoped to a single repo.

## Overview

Each day at 08:30 local time — deferred to the next wake if the machine is
asleep — `launchd` runs [`bin/daily-documenters-pr-review.sh`](./bin/daily-documenters-pr-review.sh),
which:

1. Lists open PRs on `City-Bureau/documenters` created in the current year,
   excluding bots (dependabot, renovate, coderabbitai, github-actions).
2. Skips draft PRs and any PR whose most recent review by `duongcao-ea` is
   `APPROVED`.
3. For each remaining PR, invokes headless `claude -p` with the
   `/code-review` skill and writes the review to
   `~/pr-reviews/documenters_PR<number>.md` (overwritten each run).
4. Processes PRs in parallel (default: 4 workers — lighter than scrapers
   agent since documenters PRs tend to be larger).

Reviews are written locally only; nothing is posted to GitHub. Schedule sits
between the scrapers PR review (08:00) and conflict resolver (09:00).

## Directory layout

```
documenters-pr-review-agent/
├── README.md
├── bin/
│   └── daily-documenters-pr-review.sh                # Orchestrator (install to ~/bin/)
└── launchd/
    └── com.duongcao.daily-documenters-pr-review.plist  # Schedule (install to ~/Library/LaunchAgents/)
```

## One-time setup

```bash
# 1. Copy the script to ~/bin and make it executable.
cp bin/daily-documenters-pr-review.sh ~/bin/
chmod +x ~/bin/daily-documenters-pr-review.sh

# 2. Copy the plist to LaunchAgents.
cp launchd/com.duongcao.daily-documenters-pr-review.plist ~/Library/LaunchAgents/

# 3. Reuse the existing GH PAT from Keychain (already set up by the
#    scrapers agent under the service name `daily-pr-review-gh-pat`).
#    If you haven't set it up yet:
security add-generic-password \
  -a "$USER" \
  -s daily-pr-review-gh-pat \
  -w '<your-PAT-here>' \
  -U \
  -T /usr/bin/security

# 4. Load the agent into launchd.
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.duongcao.daily-documenters-pr-review.plist

# 5. Verify it's loaded.
launchctl list | grep daily-documenters-pr-review
```

## Manual run

```bash
~/bin/daily-documenters-pr-review.sh
```

Output:
- `~/pr-reviews/documenters_PR<number>.md` — per-PR review markdown
- `~/pr-reviews/_logs/run-documenters-<YYYY-MM-DD>.log` — orchestrator log
- `~/pr-reviews/_logs/documenters_PR<number>.log` — per-PR claude stderr
- `~/pr-reviews/_logs/launchd-documenters-{stdout,stderr}.log` — launchd's stdio

## Tuning

- `MAX_PARALLEL` env var — concurrent `claude -p` calls (default 4).
- Schedule: edit the `StartCalendarInterval` block in the plist, then
  `launchctl bootout` + `bootstrap` to reload.

## Reload after edits

```bash
launchctl bootout gui/$(id -u)/com.duongcao.daily-documenters-pr-review
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.duongcao.daily-documenters-pr-review.plist
```
