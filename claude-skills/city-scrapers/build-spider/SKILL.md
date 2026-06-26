---
name: build-spider
description: Scaffold a new city-scrapers spider end-to-end — agency URL → spider class → frozen test fixture → unit test → first successful crawl. Use when the user asks to "build a spider", "add a spider", "create scraper for <agency>", or pastes a meetings page URL.
---

## When to use

User says:
- "Build a spider for <agency>"
- "Add a scraper for <URL>"
- "I need a new spider that scrapes <X>"

If they hand you only an agency name, ask for the meetings page URL before starting.

## Inputs you need

1. **Meetings page URL** — the public page listing meetings (or API endpoint).
2. **Spider slug** — `<city_prefix>_<agency_short>` (e.g. `oma_municipal_bank`, `fortx_city_council`). Match the prefix the rest of the repo uses (`scrapy list` to confirm).
3. **Agency display name** — the human-readable name (e.g. `Omaha Municipal Land Bank`).

## Process

### Step 1 — Explore the source

Delegate to the `spider-explorer` subagent if available; otherwise inline:

```bash
# Quick sniff to decide static vs dynamic vs API
curl -sI "<URL>" | head
curl -s -A "Mozilla/5.0" "<URL>" | head -200
```

Decide:
- **Static HTML** → Scrapy CSS/XPath selectors, no Playwright.
- **JS-rendered** → Playwright required (`pipenv run playwright install --with-deps firefox`).
- **JSON API** in network tab → preferred; bypass HTML parsing entirely.

If 403/Cloudflare from the start, flag it to the user — this family's User-Agent is sometimes blocked. May need a custom UA per spider (see `oma_planning_*` for the open issue).

### Step 2 — Pick the base class

From `city_scrapers_core.spiders`:

| Base class | When |
|---|---|
| `CityScrapersSpider` | Plain Scrapy, simple HTML |
| `CityScrapersCrawlSpider` | Multi-page crawl with link extraction |

If the page list + detail pages, use 2-step parse: `parse` yields requests to detail pages; `parse_meeting` returns the `Meeting`.

### Step 3 — Freeze a test fixture

```bash
curl -s -A "Mozilla/5.0" "<URL>" -o tests/files/<slug>.html
```

For dynamic pages, use Playwright to render then save HTML. Keep fixtures small — strip irrelevant sections if file is huge, but preserve all meeting blocks.

### Step 4 — Scaffold spider

`city_scrapers/spiders/<slug>.py` — minimal template:

```python
from city_scrapers_core.constants import COMMISSION  # adjust classification
from city_scrapers_core.items import Meeting
from city_scrapers_core.spiders import CityScrapersSpider


class <ClassName>Spider(CityScrapersSpider):
    name = "<slug>"
    agency = "<Agency Display Name>"
    timezone = "America/Chicago"  # adjust to city
    start_urls = ["<URL>"]

    def parse(self, response):
        for item in response.css("<meeting-block-selector>"):
            meeting = Meeting(
                title=self._parse_title(item),
                description=self._parse_description(item),
                classification=self._parse_classification(item),
                start=self._parse_start(item),
                end=self._parse_end(item),
                all_day=False,
                time_notes="",
                location=self._parse_location(item),
                links=self._parse_links(item),
                source=response.url,
            )
            meeting["status"] = self._get_status(meeting)
            meeting["id"] = self._get_id(meeting)
            yield meeting

    # … private helpers …
```

### Step 5 — Scaffold tests

`tests/test_<slug>.py`:

```python
from datetime import datetime
from os.path import dirname, join

import pytest
from city_scrapers_core.constants import PASSED, TENTATIVE
from city_scrapers_core.utils import file_response
from freezegun import freeze_time

from city_scrapers.spiders.<slug> import <ClassName>Spider

test_response = file_response(
    join(dirname(__file__), "files", "<slug>.html"),
    url="<URL>",
)
spider = <ClassName>Spider()

freezer = freeze_time("2026-06-01")
freezer.start()
parsed_items = [item for item in spider.parse(test_response)]
freezer.stop()


def test_count():
    assert len(parsed_items) > 0


def test_title():
    assert parsed_items[0]["title"] == "<expected>"


def test_start():
    assert parsed_items[0]["start"] == datetime(2026, 6, 1, 14, 0)


def test_id():
    assert parsed_items[0]["id"].startswith("<slug>/")


def test_status():
    assert parsed_items[0]["status"] in (PASSED, TENTATIVE)


def test_source():
    assert parsed_items[0]["source"] == "<URL>"
```

### Step 6 — Iterate till tests pass

```bash
pipenv run pytest tests/test_<slug>.py -v
```

Fix selectors based on failures. Don't add try/except around parse logic — let it crash so the test gives a clear pointer.

### Step 7 — Validate output schema

```bash
pipenv run scrapy validate <slug>
```

This runs city_scrapers_core's schema check. Must pass before considering done.

### Step 8 — Real crawl smoke test

```bash
pipenv run scrapy crawl <slug> -O /tmp/<slug>.json
jq 'length' /tmp/<slug>.json
jq '.[0]' /tmp/<slug>.json
```

Expect non-zero items, sensible dates (not 1900 or 2099), valid URLs in `links`, `id` unique.

### Step 9 — Lint + commit

```bash
pipenv run isort . && pipenv run black .
pipenv run flake8 .
git add city_scrapers/spiders/<slug>.py tests/test_<slug>.py tests/files/<slug>.html
git commit -m "🏗️Build spider: Add spider for <Agency Display Name>"
```

Branch naming: `feature/build-<slug>` or follow the repo's existing PR-naming convention (check `gh pr list --limit 5`).

## Edge cases to handle

- **Recurring meetings**: emit one Meeting per occurrence; do not dedupe at parse time.
- **Cancelled meetings**: set `status='cancelled'` explicitly when source indicates.
- **All-day events**: `all_day=True` and `start.time()` ignored.
- **Multiple agencies on one page**: ONE spider per agency; split if mixed.
- **Pagination**: yield request to next page from `parse`, not all at once.
- **Stale fixture**: refresh fixture every 6 months — sites change layouts.

## Anti-patterns

- ❌ Mocking `response.text` in tests; use `file_response` against a frozen fixture.
- ❌ Calling `requests.get` from inside `parse`; use `response.follow`.
- ❌ Hardcoding absolute URLs; use `response.urljoin` or `response.follow`.
- ❌ Returning items instead of yielding; breaks the Scrapy pipeline.
- ❌ Bare `except:` swallowing the real error.
