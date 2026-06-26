# Architecture — city-scrapers-* fork

This is a Scrapy project that produces public-meeting data feeds for the
[City Scrapers / Documenters](https://citybureau.org/city-scrapers) network.
Output is consumed by Documenters.org (a Django app) via the program's
`meetings_feed_endpoint`.

## Component map

```
        GitHub Actions                Azure Blob Storage              Documenters.org
   ┌────────────────────┐        ┌─────────────────────────┐        ┌──────────────────┐
   │  cron.yml (daily)  │ writes │  meetings-feed-<slug>/  │        │                  │
   │  archive.yml       ├───────►│    YYYY/MM/DD/HHMM/     │        │   Heroku app:    │
   │  staging.yml       │        │      <spider>.json      │        │   documenters-stg│
   └─────────┬──────────┘        │    latest.json          ├───────►│   documenters    │
             │                   │  meetings-feed-<slug>-stg│       │   (prod)         │
   ┌─────────▼──────────┐        └─────────────────────────┘        │                  │
   │   .deploy.sh       │                                            │  imports via     │
   │ scrapy list │ xargs│                                            │  Program.meetings│
   │ scrapy crawl {}    │                                            │  _feed_endpoint  │
   └─────────┬──────────┘                                            └──────────────────┘
             │
             ▼
   ┌────────────────────┐
   │ city_scrapers/     │
   │   spiders/*.py     │  ◄── one Spider class per agency
   │   settings/*.py    │  ◄── base | prod | staging | archive
   │   middleware.py    │
   └────────────────────┘
```

## Scrapy + city_scrapers_core layering

```
┌────────────────────────────────────────────┐
│  YOUR SPIDER (city_scrapers/spiders/X.py)  │  ← only thing you usually write
│  - inherits CityScrapersSpider              │
│  - sets name, agency, timezone, start_urls │
│  - yields Meeting(...) items                │
└────────────────────┬───────────────────────┘
                     │
┌────────────────────▼───────────────────────┐
│  city_scrapers_core (pip dep)              │
│  - CityScrapersSpider base class           │
│  - Meeting Item with required fields       │
│  - constants (TENTATIVE, PASSED, BOARD, …) │
│  - pipelines:                              │
│      MeetingPipeline      (normalize)      │
│      AzureDiffPipeline    (dedupe vs blob) │
│      OpenCivicDataPipeline (OCD format)    │
│  - extensions:                             │
│      AzureBlobFeedStorage (write feeds)    │
│      AzureBlobStatusExtension (prod only)  │
└────────────────────┬───────────────────────┘
                     │
┌────────────────────▼───────────────────────┐
│  Scrapy framework                          │
│  - Engine, Scheduler, Downloader           │
│  - Middleware: robots, retry, autothrottle │
│  - Feed exporter (JSON / JSONL)            │
└────────────────────────────────────────────┘
```

## Settings layering

`city_scrapers/settings/` has 4 modules, each inheriting `base.py`:

| Module | Used in | What changes from base |
|---|---|---|
| `base.py` | dev | dev User-Agent, MeetingPipeline only, no Azure |
| `prod.py` | `cron.yml` | prod User-Agent, AzureDiff+Meeting+OCD pipelines, status extension, writes to `AZURE_CONTAINER` |
| `staging.py` | `staging.yml` | staging User-Agent, same pipelines as prod minus status, writes to `AZURE_STAGING_CONTAINER` |
| `archive.py` | `archive.yml` | archive User-Agent, historical-scrape pipelines |

Switch settings via `SCRAPY_SETTINGS_MODULE=city_scrapers.settings.staging`
env var (workflows set this; locally you can override).

## Spider lifecycle (one crawl)

```
1. Workflow triggers (cron, push, dispatch)
2. .deploy.sh runs:  scrapy list | xargs -I {} scrapy crawl {}
3. For each spider:
   a. Scrapy resolves spider class via `name` attribute
   b. Engine calls start_requests() → yields Request to start_urls[0]
   c. parse(response) yields Meeting items
   d. Meeting passes through pipelines:
      - MeetingPipeline normalizes fields
      - AzureDiffPipeline checks last 7 days of blobs for same id;
        drops item if unchanged (saves write + downstream churn)
      - OpenCivicDataPipeline converts to OCD-event format
   e. Feed exporter writes survivors as JSONL to:
      azure://acct:key@container/YYYY/MM/DD/HHMM/<spider>.json
4. After all spiders: scrapy combinefeeds rolls them into latest.json
5. Documenters.org polls program.meetings_feed_endpoint and imports
```

## Documenters import path (what happens after the blob lands)

Triggered manually via `refresh-staging-scraped-data` skill or by a scheduled
job in the Documenters app:

```
program.meetings_feed_endpoint → handle_meetings_feed_endpoint(url)
  → fetch latest.json from Azure
  → for each item:
      - upsert Meeting on scraper_id
      - associate with Agency (auto-create from `extras.cityscrapers/agency`)
      - link to Program (this city's program)
```

Important: `program.meetings_feed_endpoint` lives in the **Documenters DB**,
not in this repo. It can point at the prod container (`meetings-feed-<slug>`)
or staging (`meetings-feed-<slug>-stg`) — see Step 10.5 of the
`refresh-staging-scraped-data` skill.

## Key invariants

- **One agency per spider** — never mix multiple boards in one spider class.
- **`scraper_id` is the join key** to Documenters — must be deterministic
  across runs (same meeting → same id).
- **Fixtures in `tests/files/` are committed** — never gitignored.
- **`.env` is gitignored** — keep Azure / Heroku credentials out of commits.

## Where things live

| What | Where |
|---|---|
| Spider classes | `city_scrapers/spiders/*.py` |
| Spider tests | `tests/test_*.py` |
| Frozen HTML fixtures | `tests/files/*.html` |
| Scrapy settings | `city_scrapers/settings/{base,prod,staging,archive}.py` |
| Dependency lock | `Pipfile.lock` |
| Deploy script | `.deploy.sh` |
| CI workflow | `.github/workflows/ci.yml` |
| Cron workflow | `.github/workflows/cron.yml` |
| Staging workflow | `.github/workflows/staging.yml` (where present) |
| Archive workflow | `.github/workflows/archive.yml` |
