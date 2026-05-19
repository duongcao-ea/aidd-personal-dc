# scrapers-pr-review-agent

A scheduled, headless AI code-review agent for open pull requests across the
`City-Bureau/city-scrapers*` repositories.

## Overview

Each day at 08:00 local time — deferred to the next wake if the machine is
asleep — `launchd` runs [`bin/daily-pr-review.sh`](./bin/daily-pr-review.sh),
which:

1. Discovers every active `City-Bureau/city-scrapers*` repository.
2. Lists open pull requests created in 2026, excluding `app/dependabot`.
3. Skips any PR whose most recent review by this account is `APPROVED`.
4. For each remaining PR, invokes headless `claude -p` with the
   `/code-review` skill and writes the review to
   `~/pr-reviews/<repo>_PR<number>.md` (overwritten each run).
5. Processes PRs in parallel (default: 6 workers).

Reviews are written locally only; nothing is posted to GitHub.

## Directory layout

```
scrapers-pr-review-agent/
├── README.md
├── bin/
│   └── daily-pr-review.sh                  # Orchestrator (install to ~/bin/)
├── launchd/
│   └── com.duongcao.daily-pr-review.plist  # Schedule (install to ~/Library/LaunchAgents/)
└── samples/
    ├── run-2026-05-12.log                  # Successful run: 7/7 reviewed, 0 failed
    └── city-scrapers-minn_PR63.md          # Example review output (real PR)
```

## Prerequisites

- `claude` CLI, authenticated (`claude auth login`).
- `gh` CLI, authenticated as `duongcao-ea`.
- The `code-review` skill installed at
  `~/.claude/skills/code-review/SKILL.md` (copied from
  `City-Bureau/city-scrapers-charnc/.claude/skills/code-review/SKILL.md`).
- macOS — the launchd plist paths are hard-coded for `/Users/duongcaochanh/`.

## Installation

```bash
cp bin/daily-pr-review.sh ~/bin/daily-pr-review.sh
chmod +x ~/bin/daily-pr-review.sh
cp launchd/com.duongcao.daily-pr-review.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.duongcao.daily-pr-review.plist
```

## Manual run

```bash
bash ~/bin/daily-pr-review.sh

# Override parallelism:
MAX_PARALLEL=12 bash ~/bin/daily-pr-review.sh
```

## Logs

- Orchestrator: `~/pr-reviews/_logs/run-<date>.log`
- Per-PR Claude transcript: `~/pr-reviews/_logs/<repo>_PR<number>.log`

See [`../../docs/agent-operations.md`](../../docs/agent-operations.md) for
conventions shared with the other agents.
