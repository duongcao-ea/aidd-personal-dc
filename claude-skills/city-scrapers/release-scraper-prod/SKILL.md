---
description: Release a single scraper to production - merge PR to main, refresh feed, clean prod DB (no-assignment meetings only), re-import
---

## Quick Start

```
/release-scraper-prod
```

Claude will prompt for the scraper identifier and walk through each step interactively, asking for explicit confirmation before every destructive or prod-touching action.

## Purpose

Roll out a single scraper to **production** end-to-end:

1. Identify the scraper's file and its city-scrapers* repo.
2. Locate any open/recent PRs that touch that scraper, merge the chosen one to `main` (or fall back to a manual staging merge if not ready).
3. (Optional) Clean stale JSON feed files for that scraper in Azure so the next run is fresh.
4. Trigger the scraper's production run on `main`.
5. Once the new `latest.json` is up, delete that scraper's meetings from `documenters-prod` that have no documenter assignments.
6. Re-import the feed so meetings re-populate from the current source.

**This skill targets `documenters-prod`.** Every destructive prod action must be explicitly confirmed by the user before execution. Defaults are conservative.

## Required inputs

Only **one** input is strictly required from the user:

- **`SPIDER_NAME`** — exact spider `name` attribute, e.g. `fortx_Fort_Worth_Public_Meetings`. This is also the prefix of `Meeting.scraper_id` in documenters DB.

The user can supply this in **any** of these forms:

1. **Bare spider name:** `fortx_Fort_Worth_Public_Meetings` — used as-is.

2. **Free-form Airtable / Slack paste** containing the spider name somewhere. Common shape: a tab-separated row from Airtable's QA / scraper-tracker table where one column holds the spider name (e.g. `charnc_meck_schools`, `fortx_Fort_Worth_Public_Meetings`).

   Extraction rule: pick the token matching `^[a-z0-9]+_[A-Za-z0-9_]+$` that also exists as a spider file in some local `city-scrapers*` checkout. Multiple candidate tokens → ask which. No matching spider file → fuzzy match + confirm.

3. **PR URL or PR number** (e.g. `https://github.com/City-Bureau/city-scrapers-fortx/pull/17` or just `17` + repo). Extract `SPIDER_NAME` directly from the spider's `name = "..."` class attribute in the PR's code — that's the canonical source the meetings feed uses:

   ```bash
   # Fetch the list of files the PR touches, find spider file(s) under city_scrapers/spiders/
   PR_FILES=$(gh pr view <PR_NUMBER> --repo City-Bureau/<REPO> --json files --jq '.files[].path' \
     | grep -E '^city_scrapers/spiders/.*\.py$')

   # For each spider file in the PR, pull the spider's `name = "..."` from the PR's head ref
   for f in $PR_FILES; do
     gh api "repos/City-Bureau/<REPO>/contents/$f?ref=$(gh pr view <PR_NUMBER> --repo City-Bureau/<REPO> --json headRefName --jq .headRefName)" \
       --jq '.content' \
       | base64 --decode \
       | grep -E '^[[:space:]]+name[[:space:]]*=[[:space:]]*"' \
       | head -1 \
       | sed -E 's/^[[:space:]]+name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'
   done
   ```

   If the PR touches multiple spider files (e.g. a sweep across spiders), surface the list and ask which spider this release is for — the skill is per-scraper, one at a time.

   Equivalent for a local checkout if the PR is already merged or fetched as a branch:

   ```bash
   git -C ~/duong.cao/<REPO> show <BRANCH_OR_SHA>:<spider_file> \
     | grep -E '^[[:space:]]+name[[:space:]]*=[[:space:]]*"' \
     | head -1 \
     | sed -E 's/^[[:space:]]+name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/'
   ```

Always echo the extracted `SPIDER_NAME` back to the user and require y/N confirmation before moving past Step 0. The spider's `name` attribute is the source of truth — if it disagrees with whatever the user said (Airtable, memory, etc.), the code wins.

Everything else is **discovered** (see Step 1). Confirm the discovered values with the user before proceeding.

- **`SCRAPER_REPO`** — discovered by scanning `~/duong.cao/city-scrapers*` repos and/or matching the spider's prefix against each repo's `.env` `AZURE_CONTAINER` and/or querying `documenters-prod` for the matching `Program.scraper_prefixes`.
- **`PROGRAM_SLUG`** — discovered by querying `documenters-prod` for the program whose `meetings_feed_endpoint` matches the discovered Azure container, or whose `scraper_prefixes` contains the spider's prefix.
- **`AZURE_CONTAINER`** — the repo's `.env` holds the **staging** container (e.g. `meetings-feed-fortx-stg`). The skill derives the **production** container by stripping the `-stg` suffix (→ `meetings-feed-fortx`) and uses only that for prod operations.
- **`PR_NUMBER`** (optional) — if user already knows which PR to merge, accept it directly and skip discovery.

## Environment

The scraper repo's `.env` provides Azure credentials:

```bash
# Source the scraper repo's .env (read-only export)
set -a && source ~/duong.cao/<SCRAPER_REPO>/.env && set +a
echo "ACCOUNT_NAME=$AZURE_ACCOUNT_NAME"
echo "KEY length=${#AZURE_ACCOUNT_KEY}"  # never echo the key itself
```

Heroku CLI must be authenticated (`heroku whoami` should return a user). `documenters-prod` is **hardcoded** for prod operations; the skill must refuse to substitute another app name.

## Process

### Step 0: Confirm intent and inputs

Print a summary and ask the user to confirm before doing anything:

```
About to release scraper to PRODUCTION:
  Spider:     <SPIDER_NAME>
  Repo:       <SCRAPER_REPO>
  Program:    <PROGRAM_SLUG>
  Heroku app: documenters-prod
  Azure:      <AZURE_CONTAINER_PROD>  (prod; .env had <AZURE_CONTAINER_STG>)

Proceed? [y/N]
```

Stop unless the user explicitly answers yes.

### Step 1: Discover repo, program, and Azure container

**1a. Locate the spider file across every local `city-scrapers*` checkout.** Don't assume the user is in the right repo:

```bash
# Scan ALL scraper repos, not just current directory
mapfile -t HITS < <(find ~/duong.cao -maxdepth 4 -type f \
  -path "*/city-scrapers*/city_scrapers/spiders/${SPIDER_NAME}.py" 2>/dev/null)

echo "Matches:"
printf '  %s\n' "${HITS[@]}"
test "${#HITS[@]}" -ge 1 || { echo "Spider file not found in any local city-scrapers* checkout"; exit 1; }
```

If multiple hits (shouldn't happen, but possible if the user has duplicates), surface the list and ask which one to use.

`SCRAPER_REPO` = the directory name two levels above the spider file (e.g. `city-scrapers-fortx`).

**1b. Verify spider `name` attribute matches `SPIDER_NAME`:**

```bash
grep -E '^\s*name\s*=' "$SPIDER_FILE" | head -1
```

If it doesn't match exactly, stop.

**1c. Discover the Azure container + credentials** (don't echo the key):

⚠️ The container in `.env` is the **staging** container (with a `-stg` suffix, e.g. `meetings-feed-fortx-stg`). Production drops the suffix (e.g. `meetings-feed-fortx`). Always strip `-stg` before any prod operation.

The Azure storage **account** (`AZURE_ACCOUNT_NAME` / `AZURE_ACCOUNT_KEY`) is shared across **all** city-scrapers repos — only the container differs per repo. So if the target repo has no `.env`, source any peer `city-scrapers*/.env` for credentials and override `AZURE_CONTAINER`:

```bash
ENV_FILE=~/duong.cao/${SCRAPER_REPO}/.env

if [ -f "$ENV_FILE" ]; then
  # Repo has its own .env — use it as-is, then strip -stg
  set -a && source "$ENV_FILE" && set +a
  AZURE_CONTAINER_STG="$AZURE_CONTAINER"
else
  # Fallback: borrow credentials from any peer city-scrapers* repo's .env
  PEER_ENV=$(find ~/duong.cao -maxdepth 2 -type f -path '*/city-scrapers*/.env' \
    -not -path "*/${SCRAPER_REPO}/*" 2>/dev/null | head -1)
  test -n "$PEER_ENV" || { echo "No .env in $SCRAPER_REPO and no peer .env found"; exit 1; }
  echo "No .env in $SCRAPER_REPO; borrowing creds from $PEER_ENV"
  set -a && source "$PEER_ENV" && set +a
  AZURE_CONTAINER_STG="$AZURE_CONTAINER"  # this is the peer's staging container, not ours
fi

# Derive THIS repo's prod container from its prefix (override whatever was sourced).
# Prefix convention: city-scrapers-<prefix> → meetings-feed-<prefix>.
# When the repo name's prefix differs from the spider's prefix (e.g. dallas repo, spider prefix "daltx"),
# prefer the spider's prefix since it matches the Azure container naming.
SPIDER_PREFIX="${SPIDER_NAME%%_*}"
AZURE_CONTAINER_PROD="meetings-feed-${SPIDER_PREFIX}"
export AZURE_CONTAINER="$AZURE_CONTAINER_PROD"  # override for the rest of the skill

echo "AZURE_ACCOUNT_NAME=$AZURE_ACCOUNT_NAME"
echo "AZURE_CONTAINER_STG (sourced, for reference)=$AZURE_CONTAINER_STG"
echo "AZURE_CONTAINER_PROD (derived from spider prefix)=$AZURE_CONTAINER_PROD"

# Safety check: prod must not end in -stg
case "$AZURE_CONTAINER_PROD" in
  *-stg) echo "ERROR: production container still has -stg suffix"; exit 1 ;;
esac

# Sanity check: container actually exists in this storage account.
az storage container show \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --name "$AZURE_CONTAINER_PROD" \
  --query "name" -o tsv 2>&1 | tail -1
```

If the container-show fails, the derived name is wrong — surface the error and ask the user to provide `AZURE_CONTAINER_PROD` manually.

For the rest of the skill, `AZURE_CONTAINER` (the variable used in every prod step) is **`AZURE_CONTAINER_PROD`** — never the staging value. If you ever need to do something on staging from this skill, that's the wrong skill; use `refresh-staging-scraped-data` instead.

**1d. Discover the `PROGRAM_SLUG`** by querying `documenters-prod` (read-only) — match either by feed endpoint or by `scraper_prefixes`:

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.accounts.models import Program

container = "${AZURE_CONTAINER_PROD}"
endpoint_suffix = f"/{container}/latest.json"

# Primary lookup: by feed endpoint
prog = Program.objects.filter(meetings_feed_endpoint__endswith=endpoint_suffix).first()

# Fallback: by scraper_prefixes (e.g. "fortx" in ["fortx"])
if prog is None:
    prefix = "${SPIDER_NAME}".split("_", 1)[0]
    prog = Program.objects.filter(scraper_prefixes__contains=[prefix]).first()

if prog:
    print(f"PROGRAM_SLUG={prog.slug}")
    print(f"PROGRAM_NAME={prog.name}")
    print(f"FEED_ENDPOINT={prog.meetings_feed_endpoint}")
    print(f"SCRAPER_PREFIXES={list(prog.scraper_prefixes)}")
else:
    print("PROGRAM_NOT_FOUND")
PYEOF
```

If `PROGRAM_NOT_FOUND`, stop and ask the user to provide `PROGRAM_SLUG` manually.

**1e. Show a discovery summary and confirm:**

```
Discovered:
  SPIDER_NAME:      <SPIDER_NAME>
  SCRAPER_REPO:     <SCRAPER_REPO>   (from local checkout)
  SPIDER_FILE:      <SPIDER_FILE>
  AZURE_CONTAINER:  <AZURE_CONTAINER_PROD>  (prod; .env had staging value <AZURE_CONTAINER_STG>)
  PROGRAM_SLUG:     <PROGRAM_SLUG>   (from documenters-prod)
  PROGRAM_NAME:     <PROGRAM_NAME>
  FEED_ENDPOINT:    <FEED_ENDPOINT>

Proceed with these values? [y/N]
```

Stop unless the user confirms.

### Step 2: Identify candidate PRs across **all** scraper repos

A scraper named with prefix `X` usually lives in `city-scrapers-X`, but don't trust that — scan **every** `city-scrapers*` repo for open PRs that touch a file matching `SPIDER_NAME`. This catches the case where a fix landed in a different repo than expected (e.g. monorepo migration in progress, mistaken repo choice by author).

**2a. Build the list of scraper repos to scan.** Prefer the local checkouts (the user has them already) and fall back to a GitHub search:

```bash
# Local checkouts — require a city_scrapers/spiders/ subdir so we don't match
# unrelated dirs like city-scrapers-analyzer-skill that happen to share the prefix
mapfile -t LOCAL_REPOS < <(
  find ~/duong.cao -maxdepth 2 -type d -name 'city-scrapers*' \
    -exec test -d '{}/city_scrapers/spiders' \; -print | xargs -n1 basename
)

# Fallback / sanity check: list all such repos on the org
GH_REPOS=$(gh repo list City-Bureau --limit 200 --json name --jq '.[].name' | grep '^city-scrapers')

# Union (deduped). The user's local checkouts take priority because we'll merge against them.
REPOS=$(printf '%s\n' "${LOCAL_REPOS[@]}" $GH_REPOS | sort -u)
echo "Scanning repos:"
printf '  %s\n' $REPOS
```

**2b. For each repo, list open PRs touching the spider — including review state:**

Approver is hardcoded to `duongcao-ea` — the reviewer whose approval gates the release.

```bash
echo "=== Open PRs touching ${SPIDER_NAME} ==="
for REPO in $REPOS; do
  # 1) Pull PRs whose changed files mention the spider name
  CANDIDATES=$(gh pr list --repo City-Bureau/$REPO --state open \
    --json number,title,headRefName,author,isDraft,createdAt,files \
    --jq '[.[] | select(.author.is_bot == false and .isDraft == false)
                | select(.files[]?.path | contains("'"${SPIDER_NAME}"'"))
                | {number, title, headRefName, author: .author.login, createdAt}]' 2>/dev/null)

  # 2) For each candidate PR, enrich with reviewDecision and duongcao-ea's latest review state
  echo "$CANDIDATES" | jq -c '.[]?' | while read -r PR; do
    NUM=$(echo "$PR" | jq -r .number)
    DETAIL=$(gh pr view "$NUM" --repo City-Bureau/$REPO \
      --json reviewDecision,reviews \
      --jq '{
        reviewDecision,
        approver_approved: ([.reviews[] | select(.author.login == "duongcao-ea") | .state]
                            | reverse | first == "APPROVED")
      }' 2>/dev/null)
    echo "$PR" | jq --argjson d "$DETAIL" '. + $d + {repo: "'"$REPO"'"}'
  done
done
```

Display **all** results across repos in a single table with the approver column:

| Repo | PR # | Title | Branch | Author | Created | reviewDecision | `duongcao-ea` approved? |
|------|------|-------|--------|--------|---------|----------------|-------------------------|

`approver_approved` is `true` only when the **latest** review from `duongcao-ea` is `APPROVED` (a later `CHANGES_REQUESTED` or `DISMISSED` flips it to `false`).

**2c. Also surface recently merged PRs across all repos** (last 20 per repo) for context — useful to spot a recent fix landed elsewhere:

```bash
for REPO in $REPOS; do
  gh pr list --repo City-Bureau/$REPO --state merged --limit 20 \
    --search "${SPIDER_NAME} in:title,body" \
    --json number,title,mergedAt \
    --jq '.[] | "'"$REPO"' #" + (.number|tostring) + " " + .title + " (merged " + .mergedAt + ")"' 2>/dev/null
done
```

**2d. Ask the user to pick a PR:**

- The user picks one PR (repo + PR #) to release.
- Or "none" if `main` of the spider's repo is already correct and they just want to re-trigger the prod data steps.
- If multiple open PRs across different repos touch the same spider, surface that as a warning — usually a sign of duplicated work that should be sorted out before release.

If the chosen PR is **in a different repo than the one `SCRAPER_REPO` resolved to in Step 1**, stop and surface the conflict — likely the spider is being moved between repos, and the user needs to resolve where the canonical version lives before this skill proceeds.

### Step 3: Merge to `staging` first, then to `main`

The release flow is **staging → main**, not straight to main. Staging is where we verify the scraper produces sane output before promoting to production.

**3.0. 🔴 Approval gate — `duongcao-ea` must have approved the PR.**

Approver is hardcoded to `duongcao-ea`. Re-check the approval state right before merging (Step 2's snapshot can go stale if the user took a break):

```bash
STATE=$(gh pr view <PR_NUMBER> --repo City-Bureau/<SCRAPER_REPO> \
  --json reviewDecision,reviews \
  --jq '{
    reviewDecision,
    latest_from_approver: ([.reviews[] | select(.author.login == "duongcao-ea") | .state] | reverse | first)
  }')
echo "$STATE"
```

Interpret the result:

| `latest_from_approver` | Action |
|---|---|
| `APPROVED` | ✅ proceed to 3a |
| `CHANGES_REQUESTED` | 🛑 stop — fixes needed before merge |
| `COMMENTED` / `DISMISSED` / `null` (no review yet) | 🛑 stop — `duongcao-ea` must submit an approving review first |

If approval is missing, **do not merge**. Tell the user:

> PR #&lt;n&gt; has not been approved by `duongcao-ea` (latest review state: `&lt;state&gt;`). Please review and approve the PR before re-running this step, or the release will halt.

The skill must not approve the PR on the user's behalf — it can offer the URL (`gh pr view <PR_NUMBER> --web`) but the approval is a human action.

After approval, the user re-runs this step. The gate re-checks and proceeds only if the latest review from `duongcao-ea` is `APPROVED`.

**3a. Merge the PR's branch into `staging`:**

```bash
cd ~/duong.cao/<SCRAPER_REPO>
git fetch origin
git checkout staging && git pull origin staging
git fetch origin pull/<PR_NUMBER>/head:pr-<PR_NUMBER>
git merge pr-<PR_NUMBER> --no-edit -m "Merge PR #<PR_NUMBER> into staging"
# Resolve conflicts if any — ask user before applying any non-trivial resolution
git push origin staging
```

If the PR is already in `staging` (e.g. from a previous run of `merge-staging` or `refresh-staging-scraped-data`), skip the merge and just confirm `staging` contains the PR's head commit:

```bash
git log staging --oneline | grep -i "pr-<PR_NUMBER>\|<PR_HEAD_SHA>" | head -3
```

**3b. Validate on `staging`:**

Run lint + tests against the `staging` checkout before promoting:

```bash
make lint
make test || pipenv run pytest tests/ -v --tb=short
```

If either fails, **stop** — the PR needs more work before it can ship. Do not promote to main, do not touch prod.

**3c. Promote to `main`:**

After staging is green, merge the PR to `main`:

```bash
gh pr merge <PR_NUMBER> --repo City-Bureau/<SCRAPER_REPO> --squash --delete-branch=false
```

If `gh pr merge` is blocked (CI red, branch protection requiring a fresh approval, etc.), surface the reason and **stop**. Do not push directly to `main` — get the PR merged through the normal review path.

**3d. Verify `main` now contains the change:**

```bash
git checkout main && git pull origin main
git log main --oneline | head -5
```

Confirm the merge commit (or squashed commit) for `<PR_NUMBER>` is on `main`. If it's not, halt and tell the user.

**Outcome of step 3:** the change must be on **both** `staging` and `main` before the skill proceeds. If only one of them has it, stop and surface the gap.

### Step 4: Re-run lint + tests on `main`

```bash
cd ~/duong.cao/<SCRAPER_REPO>
git checkout main && git pull origin main
make lint    # or: pipenv run isort . --check-only && pipenv run black . --check && pipenv run flake8 .
make test || pipenv run pytest tests/ -v --tb=short
```

If lint or tests fail, **stop**. Do not proceed to prod data steps until main is green.

### Step 5: Clear this scraper's Azure feed blobs (last 7 days)

Delete the per-run timestamped JSON files for THIS spider from the **last 7 days** in the prod Azure container. This wipes the recent feed history so the next scraper run (Step 6) produces a clean trail without stale outputs lingering.

⚠️ Only deletes blobs whose name contains `${SPIDER_NAME}`. Other spiders in the same container are untouched. `latest.json` is **never** deleted.

**5a. Preview — list blobs in the last 7 days that match this spider:**

```bash
set -a && source ~/duong.cao/<SCRAPER_REPO>/.env && set +a

> /tmp/blobs_to_delete.txt
for d in $(seq 0 6); do
  PREFIX=$(date -u -v-${d}d +"%Y/%m/%d/")
  az storage blob list \
    --account-name "$AZURE_ACCOUNT_NAME" \
    --account-key "$AZURE_ACCOUNT_KEY" \
    --container-name "$AZURE_CONTAINER_PROD" \
    --prefix "$PREFIX" \
    --query "[?contains(name, '${SPIDER_NAME}.json')].name" \
    -o tsv >> /tmp/blobs_to_delete.txt
done

# Defensive: explicitly drop any latest.json that may have leaked into the list
grep -v '^latest.json$' /tmp/blobs_to_delete.txt > /tmp/blobs_to_delete.filtered \
  && mv /tmp/blobs_to_delete.filtered /tmp/blobs_to_delete.txt

echo "Blobs to delete: $(wc -l < /tmp/blobs_to_delete.txt | tr -d ' ')"
cat /tmp/blobs_to_delete.txt
```

Show the full list (typically 1 per day = ~7 files, more if the scraper runs multiple times per day). **Ask for explicit confirmation** before deletion. Defaults to **no**.

**5b. Delete (after explicit y):**

```bash
while read -r BLOB; do
  [ -z "$BLOB" ] && continue
  [ "$BLOB" = "latest.json" ] && { echo "REFUSED: would delete latest.json"; continue; }
  az storage blob delete \
    --account-name "$AZURE_ACCOUNT_NAME" \
    --account-key "$AZURE_ACCOUNT_KEY" \
    --container-name "$AZURE_CONTAINER_PROD" \
    --name "$BLOB"
  echo "deleted: $BLOB"
done < /tmp/blobs_to_delete.txt
```

**5c. Skip if the list is empty.** If `wc -l` returned 0, there's nothing for this spider in the last 7 days — surface that to the user (it may mean the scraper hasn't been running, which is a problem to flag before continuing).

**Hard rule:** `latest.json` is **never** deleted. The defensive `grep -v` above plus the in-loop check are both required — do not collapse them.

### Step 6: Trigger the production scraper run

Two paths — ask which the user prefers:

**Path A — wait for the scheduled cron** (safest, no action needed). Tell user the next cron run will produce a fresh `latest.json`. Skill pauses here until the user confirms cron has completed.

**Path B — trigger manually via GitHub Actions:**

🔴 **Before triggering, cancel any in-progress Cron runs in this repo.** A `workflow_dispatch` trigger does NOT cancel earlier in-progress runs — they keep going and will overwrite `latest.json` and write new timestamped blobs *after* the Step 5 clear, undoing the cleanup. Always pre-empt:

```bash
# Find any in_progress Cron runs and cancel them
IN_PROG=$(gh run list --repo City-Bureau/<SCRAPER_REPO> --workflow=Cron --limit 10 \
  --json databaseId,status --jq '.[] | select(.status=="in_progress" or .status=="queued") | .databaseId')

for RID in $IN_PROG; do
  echo "Cancelling in-progress Cron run $RID"
  gh run cancel "$RID" --repo City-Bureau/<SCRAPER_REPO> 2>&1 | tail -1
done

# Wait briefly for cancellations to settle before re-triggering
sleep 5
```

If `IN_PROG` is non-empty, **also re-run Step 5** (Azure blob clear) before triggering — the in-progress runs may have written today's timestamped blobs while you were preparing, polluting the trail you just cleaned.

Then trigger fresh:

```bash
# Find the scraping workflow (usually cron.yml or scrape.yml)
gh workflow list --repo City-Bureau/<SCRAPER_REPO>
gh workflow run <workflow-file> --repo City-Bureau/<SCRAPER_REPO> --ref main \
  -f spider="${SPIDER_NAME}"   # only if the workflow accepts a spider input
```

Note: the Cron workflow in city-scrapers repos typically runs **all** spiders, not just one. If you're releasing multiple spiders from the same repo in the same session, a single trigger covers them all — don't trigger per-spider.

Watch:

```bash
gh run list --repo City-Bureau/<SCRAPER_REPO> --workflow=<workflow-file> --limit 3
gh run watch --repo City-Bureau/<SCRAPER_REPO>
```

Once the run finishes, verify `latest.json` was updated:

```bash
az storage blob show \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER_PROD" \
  --name latest.json \
  --query "properties.lastModified" -o tsv
```

Tell the user when `latest.json` was last modified. If it's not from the run we just triggered/waited on, stop and investigate.

### Step 6.5: 🔴 Hard gate — verify `latest.json` has data for this spider

**This is a mandatory precondition for any prod DB deletion.** `latest.json` is what the import in Step 9 actually consumes. If it doesn't contain records for THIS spider, re-importing will leave the scraper with zero meetings in prod — worse than the original problem. Stop here unless the check below passes.

```bash
az storage blob download \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER_PROD" \
  --name latest.json \
  --file /tmp/latest.json \
  --no-progress

# Confirm latest.json was updated recently
az storage blob show \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER_PROD" \
  --name latest.json \
  --query "properties.lastModified" -o tsv

# Filter for this spider's records (scraper_id / source markers include the spider name)
HITS=$(grep -c "$SPIDER_NAME" /tmp/latest.json || true)
echo "Records mentioning ${SPIDER_NAME} in latest.json: $HITS"

if [ "${HITS:-0}" -lt 1 ]; then
  echo "STOP: latest.json contains no records for ${SPIDER_NAME}. Re-importing would wipe this scraper's meetings from prod."
  echo "Likely causes: scraper failed on the last run, was renamed, or its output wasn't merged into latest.json."
  exit 1
fi

# Sample one record for sanity
grep "$SPIDER_NAME" /tmp/latest.json | head -1 | python3 -m json.tool | head -15
```

Show the count, the `lastModified` timestamp, and the sample record to the user. **Require explicit y/N to proceed.** Defaults to **no**. Do not move on to Step 7 unless `HITS >= 1` and the user confirms.

If `HITS == 0`, common next steps:
- Re-trigger the scraper (back to Step 6) and wait for `latest.json` to update.
- Check the workflow logs to see why the scraper produced no output.
- Confirm the scraper's `name` attribute hasn't been renamed (mismatch between `SPIDER_NAME` and what gets written into the feed).

### Step 6.6: Ensure agency exists in prod, wired to this scraper

Before re-importing, prod needs an `Agency` row that owns `SPIDER_NAME` and is not flagged as testing.

**6.6a. Detect `AGENCY_NAME` from the spider's code.** Every `city-scrapers-core` spider declares `agency = "..."` as a class attribute — that's the canonical source the meetings feed uses, so it must match what we register on the documenters `Agency` row.

```bash
# Pull the agency class attribute from the spider file (PR's merged code on main)
AGENCY_NAME=$(grep -E '^[[:space:]]+agency[[:space:]]*=[[:space:]]*"' "$SPIDER_FILE" \
  | head -1 \
  | sed -E 's/^[[:space:]]+agency[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
echo "Spider file: $SPIDER_FILE"
echo "Detected agency name: $AGENCY_NAME"
```

Example match in `fortx_Fort_Worth_Public_Meetings.py`:

```python
class FortxFortWorthPublicMeetingsSpider(CityScrapersSpider):
    name = "fortx_Fort_Worth_Public_Meetings"
    agency = "Fort Worth Public Meetings"   # ← this is the AGENCY_NAME we register
    timezone = "America/Chicago"
```

If extraction returns empty, the spider may use a different convention. Fallbacks in order:

1. **Multi-line / dynamic `agency`** (e.g. `agency = self._get_agency()` or assigned in `__init__`): grep more broadly and surface the matching line to the user:
   ```bash
   grep -nE '(^|[[:space:]])agency[[:space:]]*=' "$SPIDER_FILE"
   ```
   Ask the user to pick the right value.
2. **PR title parsing** as a last code-based fallback:
   ```bash
   PR_TITLE=$(gh pr view <PR_NUMBER> --repo City-Bureau/<SCRAPER_REPO> --json title --jq .title)
   AGENCY_NAME=$(echo "$PR_TITLE" | sed -E 's/^[^A-Za-z]+//; s/^(Build|Fix) [Ss]pider[[:space:]]*:[[:space:]]*//I; s/^Add spider for[[:space:]]+//I; s/[[:space:]]+$//')
   ```
3. **Ask the user** if all of the above fail.

Echo the detected `AGENCY_NAME` to the user and require **y/N confirmation** before continuing. The agency name is the join key for every meeting this scraper writes to documenters — a mismatch here orphans meetings on import.

**6.6b. Check, then upsert in one shell call:**

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.meetings.models import Agency
from documenters.accounts.models import Program

name = "${AGENCY_NAME}"
spider = "${SPIDER_NAME}"
program = Program.objects.get(slug="${PROGRAM_SLUG}")

# Match agency by name — exact first, partial fallback
agency = (
    Agency.objects.filter(name__iexact=name).first()
    or Agency.objects.filter(name__icontains=name).first()
)

if agency:
    print(f"Found existing agency id={agency.id} name={agency.name!r}")
    print(f"  before: scraper_names={list(agency.scraper_names)} is_testing_scraper={agency.is_testing_scraper}")
    dirty = False
    if spider not in agency.scraper_names:
        agency.scraper_names = list(agency.scraper_names) + [spider]
        dirty = True
    if agency.is_testing_scraper:
        agency.is_testing_scraper = False
        dirty = True
    if dirty:
        agency.save(update_fields=["scraper_names", "is_testing_scraper"])
        print(f"  after:  scraper_names={list(agency.scraper_names)} is_testing_scraper={agency.is_testing_scraper}")
    else:
        print("  no changes needed")
else:
    print(f"No agency matches {name!r}, creating new one for program {program.slug!r}")
    agency = Agency.objects.create(
        name=name,
        scraper_names=[spider],
        is_testing_scraper=False,
    )
    # Link to program — adjust per model: M2M (.programs.add) or FK (.program)
    if hasattr(agency, "programs"):
        agency.programs.add(program)
    elif hasattr(agency, "program"):
        agency.program = program
        agency.save(update_fields=["program"])
    print(f"  created id={agency.id} name={agency.name!r}")

assert spider in agency.scraper_names, "spider not registered on agency"
assert agency.is_testing_scraper is False, "agency still flagged as testing"
print(f"OK: agency id={agency.id} owns {spider}, is_testing_scraper=False")
PYEOF
```

If the partial match resolves to an agency the user did **not** intend, the script will silently update the wrong row. To avoid that:

- The skill must **print the matched agency before writing** (which it does).
- If the matched name doesn't read like an obvious match, **stop and ask** the user to confirm or override with an exact name.

If `Agency.objects.create` fails because of required fields (`slug`, `classification`, `website`, etc.), surface the error and ask the user to supply the missing values — don't guess. The agency is the anchor for every meeting this scraper imports.

### Step 7: Preview prod cleanup (read-only)

**Hardcoded app:** `documenters-prod`. Refuse to substitute.

> 🛡️ **The deletion is scoped to scraped meetings WITHOUT documenter assignments only.**
> Required filter triplet (Steps 7 and 8 both use it — do not relax any line):
> - `Meeting.objects.scraped()` — exclude manually-created meetings
> - `scraper_id__startswith="${SPIDER_NAME}"` — scope to this one spider
> - `assignments__isnull=True` — **never** delete a meeting a documenter has signed up for
> - `.distinct()` — avoid duplicate rows from join expansion

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.meetings.models import Meeting

qs = Meeting.objects.scraped().filter(
    scraper_id__startswith="${SPIDER_NAME}",
    assignments__isnull=True,
).distinct()

print(f"Candidates to delete: {qs.count()}")

# Safety: make sure no row in the queryset has any assignment
leaks = qs.filter(assignments__isnull=False).distinct().count()
print(f"Rows with assignments accidentally in set (must be 0): {leaks}")
assert leaks == 0, "Preview queryset would delete meetings with assignments. Stop."

if qs.exists():
    sample = qs.first()
    print(f"Sample scraper_id: {sample.scraper_id!r}")
    print(f"Sample slug:       {sample.slug}")
    print(f"Sample start_date: {sample.start_date}")
    print(f"Sample has assignments: {sample.assignments.exists()} (must be False)")
PYEOF
```

Show the count and sample to the user. **Ask for explicit confirmation** before deletion. Defaults to **no**.

### Step 8: Delete prod meetings (no-assignment only)

The deletion must use the **exact same filter triplet** as Step 7. The query is re-built inside the Heroku shell rather than reused — that's intentional so a stale handle from the preview can't accidentally widen the delete.

**8.0. 🔴 Re-verify `latest.json` still has data for this spider — immediately before the delete.**

Step 6.5 ran the same check, but minutes/hours may have passed (especially if Step 6.6 took the user offline to fix an agency, or 6.6 invoked the agency-create path). The skill must not delete anything in prod unless `latest.json` *right now* still contains records the re-import will repopulate from.

```bash
set -a && source ~/duong.cao/<SCRAPER_REPO>/.env && set +a

az storage blob download \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER_PROD" \
  --name latest.json \
  --file /tmp/latest.recheck.json \
  --no-progress

LAST_MODIFIED=$(az storage blob show \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER_PROD" \
  --name latest.json \
  --query "properties.lastModified" -o tsv)

HITS=$(grep -c "$SPIDER_NAME" /tmp/latest.recheck.json || true)
echo "latest.json lastModified: $LAST_MODIFIED"
echo "Records mentioning ${SPIDER_NAME}: $HITS"

if [ "${HITS:-0}" -lt 1 ]; then
  echo "STOP: latest.json no longer contains records for ${SPIDER_NAME}. Re-importing would wipe this scraper's meetings."
  exit 1
fi
```

If `HITS == 0`, **halt the skill** — don't even fall through to the delete. Either the scraper run was rolled back, the container was repointed, or `latest.json` was overwritten by an incomplete subsequent run. Investigate before continuing.

If `HITS >= 1`, proceed to the delete below.

**8.1. Run the delete:**

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.meetings.models import Meeting

qs = Meeting.objects.scraped().filter(
    scraper_id__startswith="${SPIDER_NAME}",
    assignments__isnull=True,
).distinct()

# Re-assert no row with assignments is in the set before deleting
leaks = qs.filter(assignments__isnull=False).distinct().count()
assert leaks == 0, "Refused: queryset includes meetings with assignments"

before = qs.count()
print(f"Before delete: {before}")

deleted, breakdown = qs.delete()
print(f"Deleted total rows: {deleted}")
print(f"Breakdown: {breakdown}")

# Post-delete sanity: meetings WITH assignments for this spider must be untouched
survivors_with_assignments = (
    Meeting.objects.scraped()
    .filter(scraper_id__startswith="${SPIDER_NAME}", assignments__isnull=False)
    .distinct()
    .count()
)
print(f"Meetings WITH assignments still in DB for this spider: {survivors_with_assignments}")
PYEOF
```

Required filters (do not relax — repeated here so it's right next to the destructive call):

- ✅ `Meeting.objects.scraped()` — exclude manually-created meetings.
- ✅ `scraper_id__startswith="${SPIDER_NAME}"` — scope to one spider.
- ✅ `assignments__isnull=True` — **never** delete meetings with documenter assignments.
- ✅ `.distinct()` — avoid duplicate rows from join expansion.

Sanity checks:

- If the **deletion count diverges from the preview** (e.g. >5× larger, or 0 when preview was >0), stop and investigate. Do not re-import on bad state.
- If the **post-delete survivors_with_assignments count** is lower than what you saw at the start of the run, **stop immediately** — meetings with assignments were touched, which means the filter triplet failed somewhere. Page for help; don't try to re-import.

### Step 9: Re-import the feed

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.accounts.models import Program
from documenters.meetings.tasks import handle_meetings_feed_endpoint

program = Program.objects.get(slug="${PROGRAM_SLUG}")
print(f"Program: {program.name}")
print(f"Feed endpoint: {program.meetings_feed_endpoint}")

result = handle_meetings_feed_endpoint.send(program.meetings_feed_endpoint)
print(f"Enqueued: {result}")
PYEOF
```

Tell the user to monitor:

```bash
heroku logs --tail -a documenters-prod --dyno worker
```

Look for `Updated meeting with id ...` entries. A typical Fort Worth feed processes in ~30s–2min.

### Step 10: Verify

After the worker drains:

```bash
heroku run --no-tty -a documenters-prod python manage.py shell <<PYEOF
from documenters.meetings.models import Meeting

qs = Meeting.objects.scraped().filter(scraper_id__startswith="${SPIDER_NAME}")
print(f"Total ${SPIDER_NAME} meetings post-import: {qs.count()}")
print(f"With assignments:    {qs.filter(assignments__isnull=False).distinct().count()}")
print(f"Without assignments: {qs.filter(assignments__isnull=True).distinct().count()}")
PYEOF
```

Spot-check on documenters.org — visit the program's upcoming meetings page (e.g. `https://documenters.org/meetings/?agency=<id>`) and confirm the previously-stale entries are gone and current source entries are present.

## Safety rules (must follow)

- **`documenters-prod` is hardcoded.** Refuse substitution. If the user asks for staging, redirect to `refresh-staging-scraped-data` instead.
- **Always preview counts before deleting.** Show the user the candidate count and sample. Require explicit y/n.
- **Never delete meetings with assignments.** The `assignments__isnull=True` filter is mandatory.
- **Never delete `latest.json`** from the Azure container — it is the live feed.
- **Never proceed past step 4 if lint/tests on `main` fail.** Bad code on main produces a bad `latest.json`, which the re-import then writes into prod.
- **If staging-only merge was used (step 3 fallback), stop after step 4.** Do not run prod data steps on a change that hasn't reached `main`.
- **Do not pass credentials through chat.** Source `.env` files; never echo the key.
- **Stop and ask on unexpected results** — preview/delete counts mismatch, scraper run produces no `latest.json`, worker logs show errors, etc.

## Output / report

When done, summarize:

- PR(s) merged and where (`main` or `staging`)
- Lint/test status on `main`
- Azure: blobs deleted (count) or skipped
- Scraper run: workflow run id + `latest.json` last modified
- Prod delete: count before, count deleted, breakdown
- Re-import: enqueued status, post-import count
- Verification: link to documenters.org program meetings page

## Error handling

- **Spider file not found** → list candidate spider files in the repo so the user can correct `SPIDER_NAME`.
- **No PRs found** → ask whether to proceed with current `main` or abort.
- **`gh pr merge` blocked** → fall back to manual staging merge, then **stop** until user gets PR to `main`.
- **Lint/test failure on main** → stop, surface failures, do not proceed.
- **Azure auth failure** → check `.env`, ask user to run `! az login` if applicable.
- **Heroku auth failure** → ask user to `! heroku login` themselves.
- **`scraped()` queryset method missing** → fall back is **not** allowed — surface the AttributeError and ask user, since dropping the filter would mass-delete manually-created meetings.
- **Worker logs show errors during import** → stop the skill, surface errors, ask user before any retry.

## Releasing multiple scrapers from the same Program in one session

> 🔴 **Critical ordering rule.** The feed endpoint is per-Program, not per-spider — a single `handle_meetings_feed_endpoint` call ingests **every** spider's records from `latest.json` at once. If any spider's `Agency.scraper_names` doesn't yet contain the spider, those records are **silently dropped** on that import (the documenters importer logs INFO only; no error). Re-running the import after wiring the agency catches them, but only because the feed hasn't changed yet — if the cron has run in between, the dropped records may be gone.

When you're releasing two or more spiders that share a Program (e.g. `daltx_school_district` + `daltx_ccc`, both in the `dallas` Program), do **not** run the per-scraper flow end-to-end serially. Instead, batch the steps that touch the shared feed:

**Batched per-program flow:**

1. **Per-spider, in parallel where possible (Steps 0–4):**
   - Discover, merge each PR to `main`, run lint + tests on `main`.

2. **Once per Program (Step 5 + Step 6):**
   - Clear last 7 days of Azure blobs for **each** spider being released (loop the cleanup; the blobs are distinct files per spider).
   - Cancel any in-progress Cron runs (Step 6 pre-trigger).
   - Trigger the Cron **once** for the repo. The workflow runs all spiders; a single fresh `latest.json` covers every spider in the Program.

3. **Per-spider gate (Step 6.5):**
   - Verify `latest.json` contains records for **each** spider being released. If any spider's HITS is 0, halt — don't proceed for any of them, since they share the same import call.

4. **Batch agency upserts (Step 6.6 for ALL spiders) — do this BEFORE any re-import:**
   - Loop the upsert across every spider being released. Confirm `scraper_names` contains the right spider and `is_testing_scraper=False` for each.
   - Only after **every** agency is wired correctly do you move to Step 7.

5. **Per-spider preview + delete (Steps 7–8):**
   - For each spider in turn, run the preview filter triplet and ask for explicit y/N before deleting. Different spiders have different prior-meeting counts and different assignment histories — surface them separately.

6. **Single re-import (Step 9) — once per Program, not once per spider:**
   - Enqueue `handle_meetings_feed_endpoint` exactly once for the Program's feed endpoint. This processes every spider's records from `latest.json` in one pass.
   - **Wait until the worker drains** before moving on. Tail `heroku logs --tail -a documenters-prod --dyno worker` and watch for the run-end log lines or `Updated meeting with id …` traffic to quiet down. A typical multi-spider feed takes ~30s–5min depending on record count.
   - Do **not** enqueue a second import for the next spider in the same Program — that's redundant and adds load. The single call already handled them.

7. **Per-spider verify (Step 10):**
   - For each spider, query post-import counts (total / with assignments / without). Spot-check on documenters.org.

**Why this ordering matters:**

- **Wiring before import:** If you upsert spider A's agency, re-import, then upsert spider B's agency and re-import again, spider B's records were silently dropped on the first import — you only recover them because the feed hasn't changed yet. If the cron fires (or you trigger another run) between the two imports, those records are gone for good in this session.
- **Single import call:** Each `handle_meetings_feed_endpoint` call walks the whole feed. Multiple calls are wasted work and produce duplicate worker log noise that hides real errors.
- **Wait for drain before next spider verify:** Counts during an in-flight import are unstable. Reading them before drain produces misleading "0 imported, did it drop them?" panic.

**Recovery if you got the ordering wrong:**

If you already enqueued the import before wiring all agencies (the mistake to avoid), the fix is:

1. Upsert the missing agency now.
2. Re-enqueue `handle_meetings_feed_endpoint` for the same Program. Idempotent — already-imported records are no-ops; previously-dropped records get picked up.
3. Verify counts for both spiders after drain.

Don't try to "patch" the missing meetings manually — re-running the import is the right fix.

## Notes

- The skill is **per-scraper**, not per-program for the merge/Azure/agency/preview/delete steps. But the **import is per-Program** — see the "Releasing multiple scrapers from the same Program" section above when more than one spider in the same Program is being released in the same session.
- The same flow works for fixes (replace a buggy version of the scraper) and for cleanups (purge stale meetings produced by an older version).
- For larger refactors that change multiple scrapers in a program, run this skill once per affected `SPIDER_NAME` rather than relaxing the filter.
- Do **not** auto-merge dependabot PRs as part of this flow — they should go through their normal review.
