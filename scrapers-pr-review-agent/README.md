# scrapers-pr-review-agent

Daily AI code-review agent for open `City-Bureau/city-scrapers*` pull requests.

## What it does

Daily at 8 AM local (deferred to first wake if Mac is asleep) `launchd` fires
[`daily-pr-review.sh`](./daily-pr-review.sh), which:

1. Discovers every active `City-Bureau/city-scrapers*` repo.
2. Lists open PRs created in 2026, excluding `app/dependabot`.
3. Filters out PRs where my latest review is `APPROVED`.
4. For each remaining PR, calls headless `claude -p` with the `/code-review`
   skill and writes the review markdown to `~/pr-reviews/<repo>_PR<num>.md`
   (overwritten on each run).
5. Runs reviews in parallel (default 6 workers).

No GitHub posting — output is local only.

## Files

| File | Purpose |
|---|---|
| `daily-pr-review.sh` | Wrapper script. Install at `~/bin/daily-pr-review.sh`. |
| `com.duongcao.daily-pr-review.plist` | launchd schedule. Install at `~/Library/LaunchAgents/`. |
| `samples/run-2026-05-12.log` | Successful manual run, 7/7 reviewed, 0 failed. |
| `samples/city-scrapers-minn_PR63.md` | Sample review output (real PR, real findings). |

## Prerequisites

- `claude` CLI authenticated (`claude auth login`)
- `gh` CLI authenticated as `duongcao-ea`
- `code-review` skill installed at `~/.claude/skills/code-review/SKILL.md` (copied
  from `City-Bureau/city-scrapers-charnc/.claude/skills/code-review/SKILL.md`)
- macOS — paths in the plist are hard-coded for `/Users/duongcaochanh/`

## Install

```bash
cp daily-pr-review.sh ~/bin/daily-pr-review.sh
chmod +x ~/bin/daily-pr-review.sh
cp com.duongcao.daily-pr-review.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.duongcao.daily-pr-review.plist
```

## Manual run

```bash
bash ~/bin/daily-pr-review.sh
# Override parallelism:
MAX_PARALLEL=12 bash ~/bin/daily-pr-review.sh
```

Logs land in `~/pr-reviews/_logs/run-<date>.log` (orchestrator) and
`~/pr-reviews/_logs/<repo>_PR<num>.log` (per-task Claude transcripts).
