---
description: Set up the full Refresh-Staging pipeline (refresh-staging.yml workflow + GitHub `staging` environment + environment/repo secrets + environment protection rule) in a city-scrapers fork. Use when the user asks to "set up refresh staging", "add the refresh-staging workflow", "wire staging refresh", or to give a city-scrapers-* repo the auto-merge → crawl → refresh-db staging pipeline. This is the heavier sibling of `setup-staging-workflow` (which only scaffolds the basic staging.yml crawl).
---

# Setup Refresh-Staging pipeline for a city-scrapers repo

Scaffolds the **Refresh Staging** GitHub Actions pipeline used by the
Documenters-linked forks (`atl`, `fortx`, `losca`, `lascruc`, `minn`, `dallas`,
`charnc`, …). Unlike `setup-staging-workflow` (which only adds the basic
`staging.yml` crawl), this sets up the full daily refresh:

```
merge-and-prepare   auto-merge open non-bot/non-draft PRs into `staging`,
                    auto-fix + verify lint, run tests, push staging
        ↓
crawl               clean the `-stg` Azure container, run all spiders to
                    staging settings, combinefeeds → fresh latest.json
        ↓
refresh-db          (Documenters-linked only) delete no-assignment staging
                    meetings for the program, queue a feed re-import
        ↓
workflow-keepalive  keep the scheduled workflow from being auto-disabled
```

## The five components this skill installs

A working refresh-staging needs **all five** — a missing one makes the workflow
fail silently or at the first job:

1. **Workflow file** — `.github/workflows/refresh-staging.yml` (template in
   `templates/refresh-staging.yml`).
2. **GitHub `staging` environment** — the `merge-and-prepare` and `refresh-db`
   jobs declare `environment: staging`; the environment must exist or the jobs
   error.
3. **Secrets** — split across repo-level and environment-level (see table).
4. **Environment protection rule** — a deployment-branch policy restricting the
   `staging` environment to the `staging` branch, so the env's secrets can't be
   exercised from arbitrary branches.
5. **Branch rulesets** (repo-level) — `Protect main` + `Protect staging` rulesets
   matching the family convention. Easy to forget; check for it explicitly with
   `gh api repos/$REPO/rulesets`. Without them the repo is unprotected even
   though the env policy exists.

## Prerequisites — basic staging must already exist

This skill adds the refresh layer **on top of** basic staging. Confirm first:

- `city_scrapers/settings/staging.py` exists (writes feeds to
  `AZURE_STAGING_CONTAINER`). If missing → run `setup-staging-workflow` first.
- A `staging` branch exists on the remote (`git ls-remote --heads origin staging`).
  If missing, create it from the default branch and push.
- `.deploy.sh` exists at repo root (the crawl job invokes it).
- `.github/workflows/cron.yml` exists — read it to learn `PYTHON_VERSION` and
  whether Playwright is installed (you'll mirror both into the new workflow).

If `setup-staging-workflow` already ran, items 1 and 3 of *its* output
(`staging.py`, basic `staging.yml`) are present. The basic `staging.yml` and
this `refresh-staging.yml` coexist — don't delete `staging.yml`.

## Pre-flight discovery (do all of this before writing anything)

```bash
REPO=City-Bureau/<repo>
LOCAL=~/duong.cao/<repo>

# 1. Confirm fork + basic staging present
ls "$LOCAL"/city_scrapers/settings/staging.py "$LOCAL"/.deploy.sh
git -C "$LOCAL" ls-remote --heads origin staging | head -1   # staging branch exists?

# 2. Default branch + python version + playwright
gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name
grep -E 'PYTHON_VERSION|playwright' "$LOCAL"/.github/workflows/cron.yml

# 3. Existing GitHub config
gh api repos/$REPO/environments --jq '.environments[]?.name'              # staging env?
gh api repos/$REPO/actions/secrets --jq '.secrets[]?.name'               # repo secrets present?
gh api repos/$REPO/environments/staging/secrets --jq '.secrets[]?.name' 2>/dev/null  # env secrets present?

# 4. Does this repo already have refresh-staging.yml?  If yes, STOP and ask.
ls "$LOCAL"/.github/workflows/refresh-staging.yml 2>/dev/null && echo "ALREADY EXISTS — ask before overwriting"
```

**Is it Documenters-linked?** It is if the program's feed is consumed by a
Documenters Heroku app. Determine the program by querying the staging
Documenters app (`documenters-stg`) or prod (`documenters-prod`):

```bash
# look up program for this repo's scraper prefix / container
heroku run --no-tty -a documenters-stg python manage.py shell <<'PYEOF'
from documenters.accounts.models import Program
for p in Program.objects.all():
    if "<prefix>" in str(list(p.scraper_prefixes)) or "<container>" in (p.meetings_feed_endpoint or ""):
        print(p.slug, "|", p.name, "|", p.meetings_feed_endpoint)
PYEOF
```

- If a program is found → **include** the `refresh-db` job; record `PROGRAM_SLUG`
  and `PROGRAM_NAME`.
- If no program (pure-feed fork) → **drop** the entire `refresh-db` job from the
  template, and skip the `HEROKU_*` / `PROGRAM_*` secrets.

## Step 1 — Scaffold the workflow file

Copy `templates/refresh-staging.yml` to `<LOCAL>/.github/workflows/refresh-staging.yml`,
then patch the three marked points:

1. **`PYTHON_VERSION`** (env block) → match `cron.yml` (`3.11` default; `fortx`
   uses `3.12`).
2. **Playwright step** in the `crawl` job → uncomment ONLY if `cron.yml` installs
   Playwright.
3. **`refresh-db` job** → keep for Documenters-linked repos; delete the whole job
   for pure-feed forks.

Optionally adjust the `schedule:` cron so this repo's refresh doesn't collide
with its prod cron (stagger by an hour or two).

Validate the YAML locally before committing:

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('$LOCAL/.github/workflows/refresh-staging.yml')); print('YAML OK')"
```

## Step 2 — Create the `staging` GitHub environment

```bash
gh api -X PUT repos/$REPO/environments/staging >/dev/null && echo "staging environment ready"
```

Idempotent — re-running just updates the (empty) environment.

## Step 3 — Set secrets

⚠️ **Never substitute a secret *value* onto a command line** (it lands in shell
history / process listings / this transcript). Two safe patterns only:
- Pipe from a command: `gh secret set NAME --body "$(some-cmd)"` — value never
  printed.
- Hand the user a `gh secret set NAME ...` command to run themselves (best for
  human-held secrets like PATs and Slack tokens).

| Secret | Scope | Required by | How to obtain |
|---|---|---|---|
| `AZURE_ACCOUNT_NAME` | repo | crawl | usually already set (shared `cityscrapers` account) |
| `AZURE_ACCOUNT_KEY` | repo | crawl | usually already set |
| `AZURE_STAGING_CONTAINER` | repo | crawl | `meetings-feed-<prefix>-stg` — usually already set |
| `SENTRY_DSN` | repo | crawl | usually already set |
| `GH_PAT` | env: staging | merge-and-prepare (push to `staging`) | **user-provided** PAT with `repo` scope |
| `SLACK_BOT_TOKEN` | env: staging | Slack notify steps | **user-provided** (shared bot token) |
| `SLACK_CHANNEL_NAME` | env: staging | Slack notify steps | **user-provided** channel id/name |
| `HEROKU_API_KEY` | env: staging | refresh-db | **user-provided** — `$(heroku auth:token)`; user should `gh secret set` it themselves |
| `HEROKU_STAGING_APP_NAME` | env: staging | refresh-db | `documenters-stg` (the shared staging app) |
| `PROGRAM_SLUG` | env: staging | refresh-db (delete filter) | from the program lookup |
| `PROGRAM_NAME` | env: staging | refresh-db (import filter) | from the program lookup |

Repo-level secrets already present in most forks (verify with the pre-flight
`actions/secrets` list); only the **environment** secrets are usually missing.

Set the non-sensitive, derivable env secrets yourself:

```bash
gh secret set PROGRAM_SLUG          --env staging -R $REPO --body "<slug>"
gh secret set PROGRAM_NAME          --env staging -R $REPO --body "<Name>"
gh secret set HEROKU_STAGING_APP_NAME --env staging -R $REPO --body "documenters-stg"
```

Hand the user the sensitive ones to run themselves (after they've confirmed/rotated):

```bash
gh secret set GH_PAT           --env staging -R $REPO          # paste PAT
gh secret set SLACK_BOT_TOKEN  --env staging -R $REPO          # paste bot token
gh secret set SLACK_CHANNEL_NAME --env staging -R $REPO        # paste channel
gh secret set HEROKU_API_KEY   --env staging -R $REPO --body "$(heroku auth:token)"
```

Confirm names landed (values are never shown): `gh secret list --env staging -R $REPO`.

## Step 4 — Environment protection rule (restrict to `staging` branch)

Restrict the environment so its secrets can only be used from the `staging`
branch (matches `fortx`: `custom_branch_policies: true`).

```bash
# Enable custom branch policies on the environment.
# NOTE: use -F (typed) not -f (string) — the API rejects "true"/"false" strings.
gh api -X PUT repos/$REPO/environments/staging \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null

# Add `staging` as the only allowed deployment branch
gh api -X POST repos/$REPO/environments/staging/deployment-branch-policies \
  -f name='staging' >/dev/null && echo "branch policy: staging only"
```

Verify:

```bash
gh api repos/$REPO/environments/staging --jq '{protection_rules, deployment_branch_policy}'
gh api repos/$REPO/environments/staging/deployment-branch-policies --jq '.branch_policies[].name'
```

## Step 4b — Branch rulesets (repo-level protection)

The family convention protects both branches with **repository rulesets** (not
classic branch protection — `branches/<b>/protection` returns 404 on these
repos). Check what a reference repo has and replicate:

```bash
gh api repos/City-Bureau/city-scrapers-fortx/rulesets --jq '.[] | "\(.id) \(.name)"'
gh api repos/City-Bureau/city-scrapers-fortx/rulesets/<id> --jq '{name,conditions,rules:[.rules[]|{type,parameters}],bypass_actors}'
gh api repos/$REPO/rulesets --jq '.[].name'   # what the target repo already has
```

Canonical shape (fortx):

- **Protect main** — `rules`: `deletion`, `non_fast_forward`,
  `pull_request` (`required_approving_review_count: 1`,
  `require_code_owner_review: true`, merge methods merge/squash/rebase).
- **Protect staging** — `rules`: `deletion`, `non_fast_forward`, `update`.
- Both: `bypass_actors: [{actor_id: 5, actor_type: RepositoryRole, bypass_mode: always}]`
  — `actor_id 5` is the **Admin** repo role. This bypass is what lets the
  `merge-and-prepare` job `git push origin staging` succeed against the `update`
  / `non_fast_forward` rules — **so the `GH_PAT` must belong to a repo admin.**

Create them (write each body to a file, POST with `--input`):

```bash
gh api -X POST repos/$REPO/rulesets --input rs_main.json    --jq '{id,name,enforcement}'
gh api -X POST repos/$REPO/rulesets --input rs_staging.json --jq '{id,name,enforcement}'
```

Implications to surface to the user before creating:
- `Protect main` makes PRs to the default branch require an approval — an open
  setup PR will then need an admin-bypass merge.
- `require_code_owner_review` only bites if the repo has a `CODEOWNERS` file.

## Step 5 — Commit on a feature branch and open a PR

Never push the workflow straight to the default branch. Branch from the default
branch, add the file, PR it.

```bash
cd "$LOCAL"
git checkout <default-branch> && git pull
git checkout -b feature/add-refresh-staging-workflow
git add .github/workflows/refresh-staging.yml
git -c user.name=duongcao-ea -c user.email=duong.cao@eastagile.com \
    commit -m "Add Refresh Staging workflow"
git push -u origin feature/add-refresh-staging-workflow
gh pr create -R $REPO --base <default-branch> --head feature/add-refresh-staging-workflow \
  --title "Add Refresh Staging workflow" \
  --body "Adds the daily refresh-staging pipeline (auto-merge PRs → crawl → refresh-db). Requires the staging environment + secrets set in this repo's settings."
```

## Step 6 — Verify (dry run)

After the PR merges (so the workflow is on the default branch and dispatchable):

```bash
gh workflow run refresh-staging.yml -R $REPO --ref staging
gh run list -R $REPO --workflow=refresh-staging.yml --limit 3
gh run watch -R $REPO <run-id>
```

Watch that `merge-and-prepare` reaches "Push staging", `crawl` writes a fresh
`latest.json` to the `-stg` container, and (if present) `refresh-db` queues the
import without error. A missing secret shows up as an immediate job failure with
a masked `***` in the log.

### ⚠️ `merge-and-prepare` merges EVERY ready non-bot PR — scope it before dispatch

The first job merges **all** open PRs where `author.is_bot == false` and
`isDraft == false` into `staging`. It does **not** filter by date, label, or
title — dispatching the workflow will pull *every* ready human PR into staging,
not just the ones you care about. Dependabot/bot PRs are auto-excluded.

Before a test (or any) dispatch, list what will be merged and confirm with the
user:

```bash
gh pr list -R $REPO --state open --json number,title,author,isDraft \
  --jq '.[] | select(.isDraft==false and (.author.login|startswith("app/")|not)) | "#\(.number) \(.title) [@\(.author.login)]"'
```

To **scope** the run to a subset (e.g. only the current sprint's scraper PRs),
temporarily convert the PRs you want skipped to **draft** (reversible — the
workflow skips drafts), dispatch, then restore them:

```bash
gh pr ready <N> --undo -R $REPO   # → draft, excluded from the run
# ... dispatch + watch ...
gh pr ready <N> -R $REPO          # restore to "ready" afterward
```

Also note: only the workflow on the **default branch** is dispatchable/scheduled
(GitHub honors `schedule` and `workflow_dispatch` only there). Merging the
workflow onto `staging` alone does **not** make it runnable — it must be on the
default branch first, even though every effect it has is staging-side.

## Safety rules

- **Never print a secret value.** Use `$(cmd)` substitution or hand the
  `gh secret set` command to the user. Never assign a secret to a shell variable
  in a way that can echo (a typo turns the assignment into a command that prints
  the value).
- **Sensitive secrets are user-held:** `GH_PAT`, `SLACK_BOT_TOKEN`,
  `SLACK_CHANNEL_NAME`, `HEROKU_API_KEY` — prefer to have the user set these.
- **Workflow goes via PR**, never a direct push to the default branch.
- **`refresh-db` deletes staging meetings** (no-assignment only, scoped to the
  program) and targets `documenters-stg` — confirm the repo is actually
  Documenters-linked before including that job.
- **Don't overwrite an existing `refresh-staging.yml`** without showing the diff
  and asking.

## Reference repos

`city-scrapers-fortx` (canonical, no Playwright, Documenters-linked),
`city-scrapers-minn` (adds a Playwright install step in crawl),
`city-scrapers-atl`, `city-scrapers-losca`, `city-scrapers-lascruc`.
