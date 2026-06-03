---
description: Refresh staging scraped data - merge PRs, clean Azure, reset DB, import
---

## Quick Start

To run this skill, use Claude Code and type:

```
/refresh-staging-scraped-data
```

Claude will guide you through each step interactively, asking for confirmation before destructive actions (like cleaning Azure or pushing to staging).

## Purpose

Complete workflow to refresh staging scraped data:

1. Clean up raw meeting data in Azure (delete all data in container)
2. Merge latest code from PRs to staging branch (lint, test, push)
3. Remove meetings data from staging Heroku database
4. Run import data command after scraping cron completes

## Environment Variables

The following env vars must be set in `.env` (example):

```bash
# Azure Storage
AZURE_ACCOUNT_NAME=cityscrapers
AZURE_ACCOUNT_KEY=<your-key>
AZURE_CONTAINER=meetings-feed-colgo-stg

# Program settings
PROGRAM_SLUG=columbia-gorge
PROGRAM_NAME=columbia
```

`.env` is gitignored — confirm with `grep '^\.env$' .gitignore` before writing,
and verify the file is not staged before any commit.

**IMPORTANT**: Heroku app is hardcoded to `<your-staging-app>` to prevent accidental production data loss.

### Convention (surveyed from sibling repos)

| Repo                 | AZURE_CONTAINER              | PROGRAM_SLUG     | PROGRAM_NAME    |
|----------------------|------------------------------|------------------|-----------------|
| city-scrapers-omaha  | `meetings-feed-oma-stg`      | `omaha`          | `omaha`         |
| city-scrapers-coloh  | `meetings-feed-coloh-stg`    | `columbus`       | `columbus`      |
| city-scrapers-colgo  | `meetings-feed-colgo-stg`    | `columbia-gorge` | `columbia`      |
| city-scrapers-atl    | `meetings-feed-atl-stg`      | `atlanta`        | `atlanta`       |
| city-scrapers-fortx  | `meetings-feed-fortx-stg`    | `fort-worth`     | `fort worth`    |
| city-scrapers-losca  | `meetings-feed-losca-stg`    | `los-angeles`    | `los angeles`   |
| city-scrapers-lascruc| `meetings-feed-lacrnm-stg`   | `las-cruces`     | `las cruces`    |
| city-scrapers-charnc | `meetings-feed-charnc-stg`   | `charlotte`      | `charlotte`     |
| city-scrapers-kancit | `meetings-feed-kancit-stg`   | `kansas-city`    | `kansas`        |
| city-scrapers-san-diego | `meetings-feed-sandie-stg`| `san-diego`      | `san diego`     |

**Pattern**: `PROGRAM_SLUG` is the dasherized city name; `PROGRAM_NAME` is the
space-separated form for `name__icontains` lookups (sometimes a shorter partial
match like `columbia` for `columbia-gorge` or `kansas` for `kansas-city`).
**Verify against the actual program in <your-staging-app>** — see Step 10.5.

## Process

### Step 1: Clean Azure Container

Ask user to confirm before cleaning the Azure container.

Load environment variables and delete all blobs in the staging container:

```bash
# Load env vars (export for use in commands)
export $(grep -v '^#' .env | xargs)

# List current blobs (to show what will be deleted)
az storage blob list --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" --container-name "$AZURE_CONTAINER" --output table

# Delete all blobs in the container
az storage blob delete-batch --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" --source "$AZURE_CONTAINER"
```

Verify the container is empty:

```bash
az storage blob list --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" --container-name "$AZURE_CONTAINER" --output table
```

Expected: No blobs listed (empty container).

### Step 2: List Open PRs

Get all open PRs excluding dependabot and drafts:

```bash
gh pr list --state open --json number,headRefName,author,isDraft | jq '[.[] | select(.author.is_bot == false and .isDraft == false)]'
```

Display the PRs to the user in a table:

| PR # | Branch | Author |
|------|--------|--------|

Ask the user which PRs to merge (default: all listed PRs).

### Step 3: Prepare Staging Branch

```bash
git fetch origin
git checkout staging
git pull origin staging
```

### Step 4: Fetch PR Branches

For each PR number, fetch using GitHub's PR refs:

```bash
git fetch origin refs/pull/<PR_NUMBER>/head:pr-<PR_NUMBER>
```

### Step 5: Merge Each PR

For each PR, merge into staging:

```bash
git merge pr-<PR_NUMBER> --no-edit -m "Merge PR #<PR_NUMBER> into staging"
```

If merge conflicts occur:
1. Stop and report the conflict to the user
2. List the conflicting files
3. Ask how to proceed (resolve manually, skip PR, or abort)

### Step 6: Run Lint Checks

Run the CI lint checks in order:

```bash
isort . --check-only
black . --check
flake8 .
```

If lint fails:
1. Run `black .` to auto-fix formatting
2. Run `isort .` to auto-fix import order
3. Re-run checks to verify fixes
4. If still failing, report specific errors

### Step 7: Run Tests

```bash
pytest tests/ -v --tb=short
```

All tests must pass before proceeding.

### Step 8: Commit Lint Fixes (if any)

If auto-formatting made changes:

```bash
git add -A
git commit -m "Fix lint errors after merge"
```

### Step 9: Verify All PRs Merged

Check that no commits remain unmerged:

```bash
for pr in <PR_NUMBERS>; do
  git log staging..pr-$pr --oneline
done
```

Empty output for each PR confirms successful merge.

### Step 10: Push to Remote

Ask user for confirmation, then:

```bash
git push origin staging
```

After push, the GitHub Actions scraping cron will run automatically.

**Important**: Tell user to monitor the GitHub Actions at:

```bash
echo "$(gh repo view --json url -q .url)/actions/workflows/staging.yml"
```

There will be 2 jobs triggered:
1. **CI** - runs lint/tests, completes quickly
2. **crawl** - runs the scrapers, takes about **30 minutes** to complete

Wait for the **crawl** job to finish before proceeding to Step 11.

### Step 10.5: Pre-flight — Verify program feed endpoint

**This step is easy to skip and costly to miss.** The omaha incident:
<your-staging-app> had `program.meetings_feed_endpoint` pointing at the **prod**
container (`meetings-feed-oma/latest.json`), not staging. Importing without
fixing this pulled prod data and silently defeated the whole refresh.

Probe first:

```bash
heroku run --no-tty -a <your-staging-app> python manage.py shell <<'PYEOF'
from documenters.accounts.models import Program
from documenters.meetings.models import Meeting

p = Program.objects.filter(slug='$PROGRAM_SLUG').first()
if not p:
    matches = list(Program.objects.filter(slug__icontains='$PROGRAM_SLUG').values_list('slug','name'))
    print('NO EXACT slug. Similar:', matches)
else:
    print(f'slug={p.slug} name={p.name}')
    print(f'feed_endpoint={p.meetings_feed_endpoint}')
    pm = Meeting.objects.filter(programs__slug=p.slug)
    print(f'total={pm.count()} with_assign={pm.filter(assignments__isnull=False).distinct().count()} without_assign={pm.filter(assignments__isnull=True).distinct().count()}')
PYEOF
```

Check the output:

- **`feed_endpoint` must contain `-stg/latest.json`** (e.g. `meetings-feed-oma-stg/latest.json`).
  If it points at the prod container (no `-stg`), update it before importing.
- Note the total / with_assign / without_assign counts — Step 11 should match these.

Update the endpoint if needed (replace `$PROGRAM_SLUG` and the new URL):

```bash
heroku run --no-tty -a <your-staging-app> python manage.py shell <<'PYEOF'
from documenters.accounts.models import Program
p = Program.objects.get(slug='$PROGRAM_SLUG')
print(f'OLD: {p.meetings_feed_endpoint}')
p.meetings_feed_endpoint = 'https://cityscrapers.blob.core.windows.net/$AZURE_CONTAINER/latest.json'
p.save(update_fields=['meetings_feed_endpoint'])
p.refresh_from_db()
print(f'NEW: {p.meetings_feed_endpoint}')
PYEOF
```

### Step 11: Delete Meetings Without Assignments

**Wait for scraping to complete first!**

Ask user to confirm the scraping cron has completed successfully.

Two variants — pick based on intent:

**Variant A — Full reset (default).** Wipes every meeting for the program that
has no assignments. Right when you've refreshed all spiders and want a clean
slate:

```bash
export $(grep -v '^#' .env | xargs)

heroku run python manage.py shell -a <your-staging-app> <<EOF
from documenters.meetings.models import Meeting

program_meetings = Meeting.objects.filter(programs__slug='$PROGRAM_SLUG')
total = program_meetings.count()
with_assignments = program_meetings.filter(assignments__isnull=False).distinct()
without_assignments = program_meetings.filter(assignments__isnull=True).distinct()

print(f'Total $PROGRAM_SLUG meetings: {total}')
print(f'With assignments: {len(with_assignments)}')
print(f'Without assignments: {len(without_assignments)}')

without_assignments.delete()
print('Deleted meetings without assignments')
EOF
```

**Variant B — Scoped to specific spiders.** Right when only a few spiders
changed and you don't want to wipe history from untouched spiders. Filter by
`scraper_id__startswith='<spider_name>/'` — the `scraper_id` format is
`<spider>/<datetime>/<hash>/<slug>`.

```bash
heroku run --no-tty -a <your-staging-app> python manage.py shell <<'PYEOF'
from documenters.meetings.models import Meeting

TARGET = ('oma_mud', 'oma_municipal_bank', 'oma_public_schools_boe')  # edit
qs = Meeting.objects.filter(programs__slug='$PROGRAM_SLUG')

# probe first
for sp in TARGET:
    sp_qs = qs.filter(scraper_id__startswith=f'{sp}/')
    sp_no_assign = sp_qs.filter(assignments__isnull=True).distinct()
    print(f'{sp}: total={sp_qs.count()} no_assign={sp_no_assign.count()}')

# then delete
for sp in TARGET:
    sp_qs = qs.filter(scraper_id__startswith=f'{sp}/').filter(assignments__isnull=True).distinct()
    n = sp_qs.count()
    if n:
        sp_qs.delete()
        print(f'{sp}: deleted {n}')
PYEOF
```

When a spider you target has 0 meetings in the DB (e.g. brand-new spider just
merged), the loop is a no-op — that's expected. The Step 12 import will create
them fresh.

### Step 11.5: Verify staging feed before queueing import

The import will pull whatever lives at `meetings-feed-<slug>-stg/latest.json`.
Confirm the blob exists and contains the items you expect — this catches the
case where `combinefeeds` didn't run or wrote 0 items:

```bash
export $(grep -v '^#' .env | xargs)

az storage blob exists \
  --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER" --name latest.json --output json

az storage blob download \
  --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER" --name latest.json \
  --file /tmp/latest.json --no-progress

python3 -c "
import json
from collections import Counter
data=[json.loads(l) for l in open('/tmp/latest.json')]
print(f'total items: {len(data)}')
by_agency=Counter(d.get('extras',{}).get('cityscrapers/agency','?') for d in data)
for a,c in by_agency.most_common():
    print(f'  {c:>4}  {a}')
"
```

Expected: total > 0, and the agencies you just refreshed appear with reasonable
counts. If a spider you expect is missing or has 0 items, investigate the
GitHub Actions log before queueing — importing an empty/broken feed wastes a
trip through the dyno.

### Step 12: Run Import Data

After deleting old meetings, run the import:

```bash
export $(grep -v '^#' .env | xargs)

heroku run python manage.py shell -a <your-staging-app> <<EOF
from documenters.accounts.models import Program
from documenters.meetings.tasks import handle_meetings_feed_endpoint

program = Program.objects.filter(name__icontains='$PROGRAM_NAME').first()
print(f'Queuing import from: {program.meetings_feed_endpoint}')
handle_meetings_feed_endpoint.send(program.meetings_feed_endpoint)
EOF
```

### Step 13: Monitor Import Progress

Monitor the import progress in Heroku logs:

**https://dashboard.heroku.com/apps/<your-staging-app>/logs**

Or via CLI:

```bash
heroku logs --tail -a <your-staging-app>
```

Look for log entries showing meetings being imported.

**Troubleshooting**: If no import logs appear, add this environment variable and rerun the import (Step 12):

```bash
heroku config:set SKIP_AZURE_BLOB_DATA_CHECK=true -a <your-staging-app>
```

Then rerun Step 12 to trigger the import again.

### Step 14: Verify Import Complete

After import finishes, verify the meeting count:

```bash
export $(grep -v '^#' .env | xargs)

heroku run python manage.py shell -a <your-staging-app> <<EOF
from documenters.meetings.models import Meeting

program_meetings = Meeting.objects.filter(programs__slug='$PROGRAM_SLUG')
total = program_meetings.count()
print(f'Total $PROGRAM_SLUG meetings: {total}')
EOF
```

### Step 15: Cleanup (if needed)

If you added `SKIP_AZURE_BLOB_DATA_CHECK` in Step 13, remove it now:

```bash
heroku config:unset SKIP_AZURE_BLOB_DATA_CHECK -a <your-staging-app>
```

## Output

Report summary:
- Azure container cleaned (via Azure CLI)
- PRs merged successfully
- PRs skipped (if any)
- Lint fixes applied (if any)
- Test results
- Push status
- Scraping workflow status
- Meetings deleted count
- Import queued status

## Error Handling

- **Azure CLI fails**: Check .env file exists and has correct credentials
- **Merge conflict**: Stop, report files, ask user
- **Lint failure**: Auto-fix with black/isort, report if still failing
- **Test failure**: Stop, report failing tests, do not push
- **Push rejected**: Report error, suggest `git pull --rebase`
- **Heroku command fails**: Report error, check Heroku status
- **Scraping fails**: Check GitHub Actions logs, report to user

## Notes

- Steps 11-12 require the **crawl** job to complete first (~30 minutes)
- Monitor the **crawl** workflow at the repo's GitHub Actions page
- Only meetings WITHOUT assignments are deleted (preserves historical data)
- To use for a different program, update `.env` with appropriate values:
  - `AZURE_CONTAINER` - the Azure blob container for the program
  - `PROGRAM_SLUG` - the program slug in the database (e.g., `columbia-gorge`)
  - `PROGRAM_NAME` - partial name match for the program (e.g., `columbia`)
- Heroku app is **always** `<your-staging-app>` (hardcoded to prevent production accidents)

## Reference: Meeting model (documenters)

Fields relevant to this skill, with the lookup patterns we actually use:

| Field            | Type          | Lookup we use                              |
|------------------|---------------|---------------------------------------------|
| `programs`       | M2M → Program | `programs__slug='omaha'`                    |
| `scraper_id`     | str           | `scraper_id__startswith='oma_mud/'`         |
| `assignments`    | reverse FK    | `assignments__isnull=True`                  |
| `data`           | JSON          | original OCD-event from feed                |
| `agency`         | FK → Agency   | human-readable agency name                  |
| `start_date`/`start_time` | date/time | scheduling                            |
| `name`           | str           | meeting title                               |

`scraper_id` format: `<spider_name>/<YYYYMMDDHHMM>/<hash>/<slug>`.
Example: `oma_mud/202507021300/x/committee_and_board_meetings`.
Splitting on the first `/` gives the spider name — used for the Variant B
scoped delete in Step 11.

`data['extras']` mirrors the city_scrapers extras; useful keys:
- `cityscrapers.org/id` (older feeds) or `cityscrapers/id` (newer) — original spider id
- `cityscrapers/agency` — human-readable agency name
- `cityscrapers/address`, `cityscrapers/time_notes`

## Anti-patterns learned the hard way

1. **Importing before fixing `meetings_feed_endpoint`** — silently pulls prod
   data. Always run Step 10.5 first.
2. **Wide deletes when only N spiders changed** — Variant A wipes all
   without-assignment meetings; that nukes history from spiders you didn't
   touch. Prefer Variant B (scoped) for incremental refreshes.
3. **Skipping the staging feed inspection** — queueing an import against an
   empty `latest.json` looks identical to a successful run until you check the
   counts in Step 14. Step 11.5 catches it ~30s earlier.
4. **Trusting that `scraper_id` matches the spider name as a substring** — it
   doesn't, because other spider names can be prefixes (e.g. `oma_planning`
   prefixes `oma_planning_exam_engineers`). Always use
   `__startswith=f'{spider}/'` with the trailing `/` to anchor at the boundary.
