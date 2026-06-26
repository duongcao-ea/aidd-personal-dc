---
name: audit-spider-health
description: Audit which spiders in this repo are healthy vs broken by parsing recent GitHub Actions cron logs. Reports per-spider item counts, 4xx/5xx rates, and identifies regressions. Use when user asks "which spiders are broken", "spider health check", "are scrapers working", or before a release.
---

## What this does

Pulls the last N successful `Cron` workflow runs from GitHub Actions for the
current repo, parses the log for each spider's `Stored jsonlines feed (X items)`
+ `response_status_count/*`, and produces a per-spider health table.

## Process

### Step 1 — Identify repo + workflow

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Repo: $REPO"

# Confirm cron.yml exists; if multiple cron-style workflows, ask which
gh workflow list -R "$REPO" --all | grep -iE "cron|schedule"
```

### Step 2 — Pull last N cron runs

```bash
N=5  # default; tune up to 14 for longer view
gh run list -R "$REPO" --workflow=cron.yml --status=success --limit "$N" \
  --json databaseId,createdAt,headSha \
  | jq -r '.[] | "\(.databaseId) \(.createdAt)"'
```

### Step 3 — Parse each run's spider results

For each run ID, extract per-spider summary lines:

```bash
parse_run() {
  local run_id=$1
  gh run view "$run_id" -R "$REPO" --log 2>/dev/null | \
    awk '
      /Stored jsonlines feed/ {
        match($0, /\(([0-9]+) items\) in: azure:[^/]*\/[^/]*\/[^/]*\/[^/]*\/[^/]*\/[^/]*\/([^.]+)\.json/, arr)
        if (arr[2] != "") items[arr[2]] = arr[1]
      }
      /response_status_count/ {
        match($0, /response_status_count\/([0-9]+)/, code)
        if (code[1] != "") status_codes[code[1]]++
      }
      END {
        for (s in items) print s, items[s]
      }
    '
}
```

Better: write a small Python helper that builds a JSON `{spider: [counts_across_runs]}`.

### Step 4 — Build the health table

Aggregate across runs into:

| Spider | Last run | Avg items (last 5) | Min | Max | 4xx/5xx | Verdict |
|---|---|---|---|---|---|---|
| `oma_mud` | 6 | 6.2 | 6 | 7 | 0 | ✅ healthy |
| `oma_municipal_bank` | 46 | 45.0 | 44 | 46 | 0 | ✅ healthy |
| `oma_planning_air` | 0 | 0.0 | 0 | 0 | 403 (5/5) | ❌ blocked |
| `oma_planning_planning` | 0 | 0.0 | 0 | 0 | 403 (5/5) | ❌ blocked |
| ... | | | | | | |

### Step 5 — Verdict heuristics

- **✅ healthy** — items > 0 in all recent runs, no 5xx.
- **⚠️ flaky** — items varies wildly (e.g. 50→0→50) — suggests intermittent block or pagination bug.
- **⚠️ shrinking** — items trending down (e.g. 30, 28, 22, 18, 12) — source may be retiring content; check if expected.
- **❌ blocked** — consistent 403/429/503 — likely WAF or UA block.
- **❌ broken** — items=0 with 200 response — selector drift, fixture stale.
- **🆕 new** — first run, no baseline.

### Step 6 — Compare against the spider list

```bash
pipenv run scrapy list > /tmp/declared-spiders.txt
# anything in the list but missing from runs = silently broken at startup
```

A spider that fails to import will show as "no log lines at all" — flag separately.

### Step 7 — Report

Output a markdown report named `SPIDER_HEALTH.md` (untracked, gitignored
automatically by `.claude/`). Format:

```markdown
# Spider health — <repo> — <date>

Based on last 5 cron runs (run IDs: …).

## Summary
- ✅ N healthy
- ⚠️ M flaky/shrinking
- ❌ K blocked/broken

## Per-spider detail
[table]

## Actionable
- [ ] Fix `<spider>` (selector drift suspected) — use `/fix-spider`
- [ ] Investigate `<spider>` 403 — likely WAF; consider custom UA
- [ ] …
```

## When to run

- **Proactive**: weekly on Monday morning.
- **Before release**: before merging staging → main.
- **After a site change**: when a maintainer announces "X city redesigned their site".
- **After Scrapy / city_scrapers_core bump**: catch import / API regressions.

## Anti-patterns

- ❌ Reporting a spider as broken from a single run — always look at ≥3 runs.
- ❌ Conflating "0 items today" with "broken" when the agency has no upcoming meetings (use prior weeks for baseline).
- ❌ Counting `workflow_dispatch` runs the same as scheduled — manual runs may have used different env.
