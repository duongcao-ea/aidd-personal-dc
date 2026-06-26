# Troubleshooting — common city-scrapers issues

Quick reference for the failure modes that come up most often. For deep dives,
delegate to the `spider-debugger` subagent.

## Spider produces 0 items in production

Common causes, ranked:

1. **403 / WAF block** — site started blocking the project User-Agent.
   - Signal: `response_status_count/403` in the run log.
   - Fix paths: custom UA in `custom_settings`, retry middleware tuning,
     Playwright with browser context.
   - See `oma_planning_*` for an open example.

2. **Selector drift** — site redesigned; current selectors no longer match.
   - Signal: `response_status_count/200` but `Stored jsonlines feed (0 items)`.
   - Fix: refresh fixture, update selectors, re-run tests.

3. **AzureDiffPipeline filtering everything** — IDs unstable across runs so
   the pipeline thinks every item is a duplicate.
   - Signal: local crawl yields N items; prod blob shows 0; `azure listing`
     for yesterday shows the same N items.
   - Fix: make `_get_id(meeting)` deterministic; usually means stripping
     timestamps or random tokens from the source ID.

4. **Source retired** — agency moved to a new platform.
   - Signal: 404 on `start_urls`.
   - Fix: locate new source URL; if none, deprecate the spider.

## CI red on a PR

```bash
# Reproduce locally
pipenv sync --dev
pipenv run isort . --check-only
pipenv run black . --check
pipenv run flake8 .
pipenv run pytest
pipenv run scrapy validate <spider>
```

Common failures:
- **isort/black diff** — auto-fix: `pipenv run isort . && pipenv run black .`
- **flake8 E501 (line too long)** — wrap the line; `noqa: E501` only for strings.
- **`scrapy validate` fails** — read the schema error; usually a missing field
  or wrong constant.

## "All spiders broken at once"

Don't fix one spider — check upstream:

```bash
# Did Pipfile.lock change recently?
git log --oneline -5 Pipfile.lock

# Did city_scrapers_core bump versions?
pipenv graph | grep city-scrapers-core

# Workflow YAML changes?
git log --oneline -5 .github/workflows/
```

If a `city_scrapers_core` API change broke a helper, every spider using that
helper breaks. Check the toolkit's CHANGELOG.

## Staging container empty after `combinefeeds`

```bash
az storage blob list --account-name $AZURE_ACCOUNT_NAME --account-key $AZURE_ACCOUNT_KEY \
  --container-name $AZURE_STAGING_CONTAINER --output table
```

If `latest.json` is missing or 0 bytes:
- `combinefeeds` failed → check workflow log.
- All spiders 0 items → expected output is empty, not really an error.
- AzureBlobStatusExtension not enabled in staging (it's not, by design).

## Documenters import succeeded but data missing

If `program.meetings_feed_endpoint` in the Documenters DB points at the prod
container instead of staging, the import silently pulls prod data. See Step 10.5
of the `refresh-staging-scraped-data` skill — it walks the probe + update under
explicit user authorization.

## Pipenv issues

```bash
# venv broken
rm -rf .venv
pipenv sync --dev

# wrong Python version
pipenv --rm
PYENV_VERSION=3.11.6/envs/scraper-env pipenv sync --dev

# Pipfile.lock conflict after merge
pipenv lock
git add Pipfile.lock
```

## Heroku commands against shared infra

Project `.claude/settings.json` denies `heroku run` by default. This is
intentional — `documenters-stg` is shared infrastructure. Any specific
invocation must be explicitly approved by the user for that session; do not
treat the rule as routine friction to work around. The
`refresh-staging-scraped-data` skill documents which commands require this
authorization and what they do.

## Azure CLI auth issues

```bash
# Test auth with env vars
az storage container show \
  --account-name "$AZURE_ACCOUNT_NAME" \
  --account-key "$AZURE_ACCOUNT_KEY" \
  --name "$AZURE_CONTAINER"

# If 401: AZURE_ACCOUNT_KEY is wrong in .env
# If 404: AZURE_CONTAINER name is wrong
# If "container key missing": .env not loaded
#   → export $(grep -v '^#' .env | xargs)
```
