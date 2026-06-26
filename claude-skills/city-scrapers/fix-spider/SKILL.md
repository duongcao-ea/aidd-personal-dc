---
name: fix-spider
description: Diagnose and fix a city-scrapers spider that's producing 0 items, throwing errors, or scraping wrong data. Use when user says "spider X is broken", "no data from <spider>", "fix the X scraper", or pastes a Scrapy traceback.
---

## When to use

User says:
- "Spider X is returning 0 items"
- "<spider> stopped working"
- "Fix the X scraper" / "Debug X"
- Pastes a Scrapy error / traceback

## Process

### Step 1 — Identify the failure mode

Run the spider in dev and capture log:

```bash
pipenv run scrapy crawl <spider> -O /tmp/<spider>.json -L INFO 2>&1 | tee /tmp/<spider>.log
```

Then classify (top 5 causes in this family):

| Symptom | Likely cause | Where to look |
|---|---|---|
| 0 items, 403/429/503 response | Bot block / WAF | `response.headers`, User-Agent, retry middleware |
| 0 items, 200 response | Selector drift (site redesign) | `tests/files/<spider>.html` vs live HTML diff |
| `IndexError` / `AttributeError` in parse | Element missing on some rows | Add `.get()`, default `''`, gate with `if` |
| `TypeError: datetime` | Date format changed | `_parse_start`, `dateutil.parser.parse` |
| Items scraped but `scrapy validate` fails | Schema regression | Required field missing or wrong type |

### Step 2 — Re-confirm with a fresh fixture

Site may have changed. Pull a fresh copy:

```bash
curl -s -A "Mozilla/5.0" "<spider URL>" -o /tmp/<spider>-fresh.html
diff <(tidy -q /tmp/<spider>-fresh.html 2>/dev/null) <(tidy -q tests/files/<spider>.html 2>/dev/null) | head -100
```

If structure differs (different classes, new wrappers), the site changed and Step 3 applies.

### Step 3 — Adjust selectors

- Prefer **CSS** over deep XPath — less brittle.
- Avoid index-based selectors (`tr:nth-child(3)`); use semantic ones (`tr.meeting-row`, `td[headers=date]`).
- For dynamic class names (`<div class="c-3xj49a">`), don't pin to them; use parent structure or text-based selectors.

### Step 4 — Update or freeze new fixture

```bash
mv /tmp/<spider>-fresh.html tests/files/<spider>.html
# adjust test expectations for new sample data
pipenv run pytest tests/test_<spider>.py -v
```

If the fixture changed substantially, expected test values (title, start, etc.) also need updating to match the new top-of-page meeting. Update both.

### Step 5 — Verify production-equivalent path

```bash
SCRAPY_SETTINGS_MODULE=city_scrapers.settings.prod \
  pipenv run scrapy crawl <spider> -O /tmp/<spider>-prod.json
jq 'length' /tmp/<spider>-prod.json
```

Prod settings include `AzureDiffPipeline` which may filter; staging settings are usually closer to dev.

### Step 6 — Compare with prior good output

```bash
# Pull yesterday's output from prod container
az storage blob download \
  --account-name "$AZURE_ACCOUNT_NAME" --account-key "$AZURE_ACCOUNT_KEY" \
  --container-name "$AZURE_CONTAINER" \
  --name "$(date -v-1d +%Y/%m/%d)/<spider>.json" \
  --file /tmp/<spider>-yesterday.json --no-progress 2>/dev/null
diff <(jq -S '.[].id' /tmp/<spider>-yesterday.json) <(jq -S '.[].id' /tmp/<spider>-prod.json)
```

### Step 7 — Commit fix

```bash
pipenv run isort . && pipenv run black . && pipenv run flake8 .
git add city_scrapers/spiders/<spider>.py tests/test_<spider>.py tests/files/<spider>.html
git commit -m "🕷️ Fix spider: <Agency Display Name>"
```

Title convention from `city-scrapers-fortx`: `🕷️ Fix spider: <agency>`.

## Specific failure recipes

### `oma_planning_*` 403 issue (Cloudflare-style)

Domain `planning.cityofomaha.org` returns 403 for the project User-Agent. Options:
1. Custom `USER_AGENT` per spider (override in `custom_settings`).
2. Add `DEFAULT_REQUEST_HEADERS` with browser-like fingerprint.
3. Last resort: Playwright with browser context.

Don't fix by setting a lying User-Agent without confirming the site's terms allow scraping.

### `freezegun` test pass but live fails

`freeze_time` masks real-time bugs. After fixing, also test without freezer:

```python
@freeze_time("2026-06-01")
def test_with_freeze():
    items = list(spider.parse(test_response))
    assert items[0]["start"] == datetime(2026, 6, 1, 14, 0)
```

If your spider does `datetime.now()` for "this year" inference, that's a real bug — pass the year explicitly.

### `AzureDiffPipeline` drops everything

If items are scraped but 0 land in Azure, it's the diff pipeline deduping against historical blobs. Check:

```bash
az storage blob list --account-name $AZURE_ACCOUNT_NAME --account-key $AZURE_ACCOUNT_KEY \
  --container-name $AZURE_CONTAINER --prefix "$(date -v-7d +%Y/%m)" \
  --query "[?contains(name, '<spider>')].name" -o table
```

If the spider ran yesterday and produced the same IDs, dedup is correct. If IDs are unstable (e.g. include timestamps), that's a bug in `_get_id`.

## Anti-patterns

- ❌ Wrapping parse in `try/except: pass` to "fix" 0 items — hides the real selector drift.
- ❌ Pinning to brittle XPath that just happens to work; future-you will hit it again.
- ❌ Adding `time.sleep` or aggressive `DOWNLOAD_DELAY` to "fix" rate limits — use `AUTOTHROTTLE_*` env vars set in the workflow.
- ❌ Skipping the fixture update when the site changed — tests will pass on stale data while prod fails.
