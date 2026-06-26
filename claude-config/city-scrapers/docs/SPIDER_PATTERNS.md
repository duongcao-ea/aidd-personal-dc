# Spider patterns — city-scrapers cookbook

Patterns observed across the city-scrapers-* family. Copy these instead of
re-inventing.

## 1. Plain static HTML page

Most common case. Page has a list of meetings rendered server-side.

```python
from city_scrapers_core.constants import BOARD
from city_scrapers_core.items import Meeting
from city_scrapers_core.spiders import CityScrapersSpider


class FooBarSpider(CityScrapersSpider):
    name = "foo_bar"
    agency = "Foo Bar Board"
    timezone = "America/Chicago"
    start_urls = ["https://example.gov/meetings"]

    def parse(self, response):
        for row in response.css("table.meetings tr.meeting"):
            meeting = Meeting(
                title=row.css(".title::text").get(default="").strip(),
                start=self._parse_start(row),
                location={"name": "City Hall", "address": "..."},
                links=self._parse_links(row),
                source=response.url,
                classification=BOARD,
                # status + id below via core helpers
            )
            meeting["status"] = self._get_status(meeting)
            meeting["id"] = self._get_id(meeting)
            yield meeting
```

Refs in this family: `coloh`, `losca`, most basic spiders.

## 2. Dynamic spider factory (one file, multiple classes)

When one city has 10+ near-identical boards (e.g. Omaha Planning), use a factory
to avoid 10 copies of the same code.

```python
# city_scrapers/spiders/oma_planning.py
class OmahaPlanningMixin:
    timezone = "America/Chicago"

    def parse(self, response):
        # shared parse logic ...
        yield meeting


SPIDER_CONFIGS = [
    {"name": "oma_planning_air", "agency": "Air Conditioning Board",
     "url": "https://planning.cityofomaha.org/boards/air-conditioning-..."},
    {"name": "oma_planning_appeals", "agency": "Administrative Board of Appeals",
     "url": "https://planning.cityofomaha.org/boards/administrative-board-..."},
    # ...
]

def _create_spiders():
    for cfg in SPIDER_CONFIGS:
        cls = type(
            f"OmahaPlanning{cfg['name'].split('_')[-1].title()}",
            (OmahaPlanningMixin, CityScrapersSpider),
            {"name": cfg["name"], "agency": cfg["agency"],
             "start_urls": [cfg["url"]]},
        )
        globals()[cls.__name__] = cls

_create_spiders()
```

Tradeoffs:
- ✓ DRY across 10 boards
- ❌ Scrapy autodiscovery sometimes misses dynamic classes; verify with
  `scrapy list`
- ❌ Tests are trickier — parametrize over configs

Refs: `city-scrapers-omaha` `oma_planning.py`.

## 3. JS-rendered page (Playwright)

When `curl` of the URL returns an empty shell.

```python
from city_scrapers_core.spiders import CityScrapersSpider
from scrapy_playwright.page import PageMethod


class JsHeavySpider(CityScrapersSpider):
    name = "city_jsheavy"
    agency = "Some Agency"
    timezone = "America/Chicago"

    def start_requests(self):
        yield scrapy.Request(
            "https://example.gov/calendar",
            meta={
                "playwright": True,
                "playwright_page_methods": [
                    PageMethod("wait_for_selector", "div.meeting-card"),
                ],
            },
        )
```

Workflow needs:
```yaml
- name: Install Playwright browsers
  run: pipenv run playwright install --with-deps firefox
```

Refs: `city-scrapers-losca`, `city-scrapers-fortx`.

## 4. JSON API (the lucky case)

If the page is React/Vue and you can see a sibling `/api/meetings` endpoint
returning JSON, skip HTML parsing entirely.

```python
import json
import scrapy

class ApiSpider(CityScrapersSpider):
    name = "city_api"

    def start_requests(self):
        yield scrapy.Request(
            "https://example.gov/api/meetings?page=1",
            callback=self.parse,
            headers={"Accept": "application/json"},
        )

    def parse(self, response):
        data = json.loads(response.text)
        for item in data["results"]:
            yield Meeting(
                title=item["title"],
                start=parse_iso(item["start"]),
                links=[{"title": "Agenda", "href": item["agenda_url"]}],
                source=response.url,
                # ...
            )
        # pagination
        if data.get("next"):
            yield response.follow(data["next"], callback=self.parse)
```

10× faster + 100× more reliable than HTML parsing. Look for an API first.

## 5. Two-stage crawl (calendar → detail page)

When the list view has only titles/dates, but full meeting metadata (location,
agenda link) is on a detail page.

```python
def parse(self, response):
    for row in response.css(".meeting-row"):
        url = response.urljoin(row.css("a::attr(href)").get())
        yield response.follow(url, callback=self.parse_meeting, meta={
            "row_title": row.css(".title::text").get(),
        })

def parse_meeting(self, response):
    yield Meeting(
        title=response.meta["row_title"] or response.css("h1::text").get(),
        # ... fields from response (detail page) ...
        source=response.url,
    )
```

Refs: `city-scrapers-atl` city_council spider, many.

## 6. Pagination

Yield the next page from `parse`, don't try to build them all upfront.

```python
def parse(self, response):
    for row in response.css(".meeting"):
        yield self._row_to_meeting(row, response)

    next_url = response.css(".pagination .next::attr(href)").get()
    if next_url:
        yield response.follow(next_url, callback=self.parse)
```

## 7. Recurring meetings

Most sites list each occurrence. Emit one Meeting per occurrence — do NOT try
to compress into a single recurring item; the schema doesn't support it.

If the site shows "Meets first Tuesday of each month", expand to N concrete
dates (next 12-18 months) explicitly:

```python
from dateutil.rrule import rrule, MONTHLY, TU

def _expand_recurring(self, agency_name):
    for dt in rrule(MONTHLY, byweekday=TU(1), count=18,
                    dtstart=datetime.now()):
        yield Meeting(
            title=f"{agency_name} Regular Meeting",
            start=dt.replace(hour=18),  # 6pm
            time_notes="Recurs first Tuesday of each month",
            # ...
        )
```

## 8. Cancelled / rescheduled handling

```python
title = row.css(".title::text").get(default="")
status_text = row.css(".status::text").get(default="").lower()

meeting = Meeting(
    title=re.sub(r"\b(cancelled|canceled)\b", "", title, flags=re.I).strip(),
    # ...
)
if "cancel" in status_text or "cancel" in title.lower():
    meeting["status"] = "cancelled"
else:
    meeting["status"] = self._get_status(meeting)
```

## 9. Anti-anti-patterns (don't do these)

```python
# ❌ Don't do this
response.css("td")[2].css("::text").get()  # fragile index

# ✓ Do this
response.css("td[headers=date]::text").get()  # semantic

# ❌ Don't do this
try:
    title = row.css(".title").extract_first().strip()
except Exception:
    title = ""

# ✓ Do this
title = row.css(".title::text").get(default="").strip()

# ❌ Don't do this — year inferred from datetime.now
month_day = "March 5"
date = datetime.strptime(f"{month_day} {datetime.now().year}", "%B %d %Y")

# ✓ Do this — year from source, or explicit handling of year boundary
year_text = response.css("h2.year::text").get()  # "Meetings: 2026"
year = int(re.search(r"\d{4}", year_text).group())
date = datetime.strptime(f"{month_day} {year}", "%B %d %Y")
```

## When unsure

1. Look for a sibling spider in the same repo with a similar source type — copy
   its structure.
2. Look for the same agency in another city-scrapers-* fork.
3. Ask the `spider-explorer` subagent to design before writing.
