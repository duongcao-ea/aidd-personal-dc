---
description: Set up the staging GitHub Actions workflow and Scrapy staging settings in a city-scrapers repo. Use when user asks to "set up staging", "add staging workflow", "add staging environment", or similar for a city-scrapers fork (city-scrapers-*).
---

# Setup Staging Workflow for a city-scrapers repo

This skill scaffolds the standard staging environment used across city-scrapers
forks (atl, coloh, fortx, losca, lascruc, etc.). It produces two files:

1. `city_scrapers/settings/staging.py` — Scrapy settings module that writes feeds
   to `AZURE_STAGING_CONTAINER` instead of the production container.
2. `.github/workflows/staging.yml` — GitHub Actions workflow that runs the
   `staging` branch on a daily cron and on push to `staging`.

Reference repos (most recent → oldest): `city-scrapers-coloh`,
`city-scrapers-fortx`, `city-scrapers-atl`, `city-scrapers-losca`,
`city-scrapers-lascruc`. Use `city-scrapers-coloh` as the canonical minimal
pattern.

## When NOT to use this skill

- Repo already has `.github/workflows/staging.yml`. Read it first and ask the
  user what they want changed.
- Repo is not a city-scrapers fork (no `city_scrapers/settings/` directory).
- User wants the `refresh-staging.yml` workflow too — that's a separate, more
  involved setup (auto-merging open PRs into `staging`, lint, tests, Slack
  notifications). Ask before adding it; only `atl`, `fortx`, `losca`, and
  `lascruc` use it. Documenters-linked repos additionally have a `refresh-db`
  job — do NOT copy that unless the repo is wired to a Heroku Documenters app.

## Pre-flight checks

Before writing anything, verify:

1. `city_scrapers/settings/base.py` exists (confirms it's a city-scrapers fork).
2. `city_scrapers/settings/prod.py` exists — read it to confirm the Azure +
   Sentry + Scrapy-Sentry-Errors stack matches the staging template. If `prod.py`
   diverges (e.g. uses a different pipeline set, no Sentry, no `OpenCivicDataPipeline`),
   adapt `staging.py` to match `prod.py`'s shape rather than blindly copying the
   template.
3. `.github/workflows/cron.yml` exists — read it to confirm:
   - `PYTHON_VERSION` (commonly `3.11`, but `fortx` uses `3.12`). Match cron.
   - Whether Playwright is installed (`pipenv run playwright install`). If
     cron.yml installs Playwright, staging.yml should too.
   - Whether `.deploy.sh` is the runner. If a different runner is used, match it.
4. `.deploy.sh` exists at repo root.
5. No existing `staging.py` or `staging.yml` (don't overwrite without asking).

## Step 1 — Create `city_scrapers/settings/staging.py`

Template (matches `city-scrapers-coloh`):

```python
import os

from .base import *  # noqa

USER_AGENT = "City Scrapers [staging mode]. Learn more and say hello at https://citybureau.org/city-scrapers"  # noqa

ITEM_PIPELINES = {
    "city_scrapers_core.pipelines.AzureDiffPipeline": 200,
    "city_scrapers_core.pipelines.MeetingPipeline": 300,
    "city_scrapers_core.pipelines.OpenCivicDataPipeline": 400,
}

SENTRY_DSN = os.getenv("SENTRY_DSN")

EXTENSIONS = {
    "scrapy_sentry_errors.extensions.Errors": 10,
    "scrapy.extensions.closespider.CloseSpider": None,
}

FEED_EXPORTERS = {
    "json": "scrapy.exporters.JsonItemExporter",
    "jsonlines": "scrapy.exporters.JsonLinesItemExporter",
}

FEED_FORMAT = "jsonlines"

FEED_STORAGES = {
    "azure": "city_scrapers_core.extensions.AzureBlobFeedStorage",
}

AZURE_ACCOUNT_NAME = os.getenv("AZURE_ACCOUNT_NAME")
AZURE_ACCOUNT_KEY = os.getenv("AZURE_ACCOUNT_KEY")
AZURE_CONTAINER = os.getenv("AZURE_STAGING_CONTAINER")

FEED_URI = (
    "azure://{account_name}:{account_key}@{container}"
    "/%(year)s/%(month)s/%(day)s/%(hour_min)s/%(name)s.json"
).format(
    account_name=AZURE_ACCOUNT_NAME,
    account_key=AZURE_ACCOUNT_KEY,
    container=AZURE_CONTAINER,
)
```

Key differences from `prod.py`:
- `USER_AGENT` says `[staging mode]` not `[production mode]`.
- `AZURE_CONTAINER` reads `AZURE_STAGING_CONTAINER` (not `AZURE_CONTAINER`).
- No `AzureBlobStatusExtension` and no `CITY_SCRAPERS_STATUS_CONTAINER` — staging
  doesn't write a status feed.

If `prod.py` for this repo uses a leaner pipeline set (e.g. no
`OpenCivicDataPipeline` or `AzureDiffPipeline`), trim `staging.py` to match. The
rule of thumb: `staging.py` mirrors `prod.py` except for the three differences
above.

## Step 2 — Create `.github/workflows/staging.yml`

Template (matches `city-scrapers-coloh`, no Playwright):

```yaml
name: Staging

on:
  schedule:
    - cron: "30 5 * * *"
  push:
    branches:
      - staging
  workflow_dispatch:

env:
  CI: true
  PYTHON_VERSION: 3.11
  PIPENV_VENV_IN_PROJECT: true
  CITY_SCRAPERS_ENV: staging
  SCRAPY_SETTINGS_MODULE: city_scrapers.settings.staging
  AUTOTHROTTLE_MAX_DELAY: 30.0
  AUTOTHROTTLE_START_DELAY: 1.5
  AUTOTHROTTLE_TARGET_CONCURRENCY: 3.0
  AZURE_ACCOUNT_KEY: ${{ secrets.AZURE_ACCOUNT_KEY }}
  AZURE_ACCOUNT_NAME: ${{ secrets.AZURE_ACCOUNT_NAME }}
  AZURE_STAGING_CONTAINER: ${{ secrets.AZURE_STAGING_CONTAINER }}
  SENTRY_DSN: ${{ secrets.SENTRY_DSN }}

jobs:
  crawl:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: staging

      - name: Set up Python ${{ env.PYTHON_VERSION }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ env.PYTHON_VERSION }}

      - name: Install Pipenv
        run: |
          python -m pip install --upgrade pip
          pip install pipenv

      - name: Cache Python dependencies
        uses: actions/cache@v4
        with:
          path: .venv
          key: ${{ env.PYTHON_VERSION }}-${{ hashFiles('**/Pipfile.lock') }}
          restore-keys: |
            ${{ env.PYTHON_VERSION }}-
            pip-

      - name: Check and conditionally remove invalid virtual environment
        run: |
          if [ -d ".venv" ] && [ ! -f ".venv/bin/python" ]; then
            echo "Virtual environment exists but Python executable is missing. Rebuilding."
            rm -rf .venv
          elif ! .venv/bin/python --version 2>&1 | grep -q "Python ${{ env.PYTHON_VERSION }}"; then
            echo "Virtual environment Python version mismatch. Rebuilding."
            rm -rf .venv
          elif [ ! -d ".venv" ]; then
            echo "No virtual environment found. Will build new one."
          else
            echo "Virtual environment appears valid. Reusing."
          fi

      - name: Install dependencies
        run: pipenv sync
        env:
          PIPENV_DEFAULT_PYTHON_VERSION: ${{ env.PYTHON_VERSION }}

      - name: Run scrapers
        run: |
          export PYTHONPATH=$(pwd):$PYTHONPATH
          ./.deploy.sh

      - name: Combine output feeds
        run: |
          export PYTHONPATH=$(pwd):$PYTHONPATH
          pipenv run scrapy combinefeeds -s LOG_ENABLED=False

  workflow-keepalive:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    permissions:
      actions: write
    steps:
      - uses: liskin/gh-workflow-keepalive@v1
```

If `cron.yml` installs Playwright, add this step **after** "Install dependencies"
and **before** "Run scrapers":

```yaml
      - name: Install Playwright browsers
        run: pipenv run playwright install --with-deps firefox
```

Match `PYTHON_VERSION` to `cron.yml`. Match the cron schedule to whatever the
repo's other staging-style forks use — `30 5 * * *` is the most common; `coloh`,
`losca` use it. `fortx` uses `0 5 * * *`. If unsure, use `30 5 * * *`.

## Step 3 — Workflow + branch hygiene

1. Create the work on a feature branch — do not commit to `main`. Suggested
   name: `feature/add-staging-workflow`.
2. Commit both files together with a message like
   `Add staging workflow and settings`.
3. **Do NOT push** without explicit user confirmation. The user typically wants
   to review the diff first.

## Step 4 — Audit GitHub Actions secrets

Run `gh secret list -R <owner>/<repo>` (e.g. `City-Bureau/city-scrapers-omaha`)
and diff against what `staging.yml` needs. Three of the four are reused from
prod and almost always already present:

| Secret | Usually present? | Needed by staging.yml |
|---|:---:|:---:|
| `AZURE_ACCOUNT_KEY` | ✓ (prod uses it) | ✓ |
| `AZURE_ACCOUNT_NAME` | ✓ (prod uses it) | ✓ |
| `SENTRY_DSN` | ✓ (prod uses it) | ✓ |
| `AZURE_STAGING_CONTAINER` | ✗ (staging-only) | ✓ |

So in practice, **`AZURE_STAGING_CONTAINER` is the only new secret to add.**

**Naming convention** (observed): `meetings-feed-<slug>-stg`, where `<slug>` is
the short city code used in the repo (e.g., `oma` for omaha, matching the spider
prefix `oma_*`). Confirm with the user before setting — sometimes the slug
differs from the repo suffix.

Set with:

```bash
gh secret set AZURE_STAGING_CONTAINER -R <owner>/<repo> -b "<container-name>"
```

Then re-run `gh secret list` to confirm the new timestamp.

## Step 5 — Tell the user what's still left

After committing and setting the secret, the only remaining items are off-repo
and can't be done from the CLI here:

- **Create a `staging` branch** in the GitHub repo. The workflow checks out
  `refs/heads/staging`; without that branch, every scheduled run fails. Easiest:
  branch from `main` once the PR adding this workflow lands.
- **Create the Azure staging container** if it doesn't exist yet. The container
  name must exactly match the value of `AZURE_STAGING_CONTAINER`.
- **Open a PR** to `main` for the staging workflow + settings.

## Reference: full vs. minimal staging setups

| Repo                  | staging.yml | refresh-staging.yml | Notes                          |
|-----------------------|:-----------:|:-------------------:|--------------------------------|
| city-scrapers-coloh   | ✓           | ✗                   | **Minimal — use as template**  |
| city-scrapers-fortx   | ✓           | ✓                   | Python 3.12, Playwright        |
| city-scrapers-losca   | ✓           | ✓                   | Has Documenters refresh-db job |
| city-scrapers-atl     | ✓           | ✓                   | Has sync-airtable.yml too      |
| city-scrapers-lascruc | ✓           | ✓                   |                                |

When in doubt, default to the minimal (coloh) pattern. The refresh-staging
workflow is a follow-up the user can request explicitly.
