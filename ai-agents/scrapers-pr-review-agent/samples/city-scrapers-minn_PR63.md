# Code Review: PR #63 — Fix spider factory for Minneapolis City

## Summary

This PR refactors 41 individual Minneapolis spider files into a single dynamically-generated spider module backed by a shared `MinnCityMixin`. The mixin now hits three LIMS attachment endpoints before the primary calendar API and stitches richer per-meeting links (video, agenda, report/proceedings) onto each meeting by date.

The consolidation is a good move and the test suite is significantly more thorough than before. There are, however, a few real bugs and several design concerns worth addressing before merge.

---

## 🔴 Bugs

### 1. Class-level date computation is frozen at import time
**File:** `city_scrapers/mixins/minn_city.py:38-40`

```python
class MinnCityMixin(...):
    timezone = "America/North_Dakota/Beulah"
    today = datetime.now(tz=ZoneInfo(timezone)).date()
    from_date = today - timedelta(days=365 * 4)
    to_date = today + timedelta(days=365)
```

These expressions evaluate **once at module import**, not on each crawl. A long-running scrapy worker (or any process that imports the module ahead of time) will keep crawling against the import-time date forever. The pre-PR code had the same problem with `from_date` but only used a 30-day window — extending the window to 4 years masks the drift but does not fix it.

**Fix:** compute these inside `start_requests()` (or `_request_primary_calendar()`), or wrap them in a `@classmethod` / `@property`.

### 2. `_parse_source` falls back to a generic calendar URL
**File:** `city_scrapers/mixins/minn_city.py:226-228`

```python
def _parse_source(self, links):
    agenda = next((l["href"] for l in links if l.get("title") == "Agenda"), None)
    return agenda or self.source_url   # = https://lims.minneapolismn.gov/Calendar/all/monthly
```

Previously the source URL was agency-specific (`/Boards/Meetings/<Abbreviation>`). Now every meeting without an agenda link falls back to the **same** generic calendar page. This degrades the public-facing source attribution for hundreds of meetings.

Suggest preserving an `Abbreviation`-based URL as the fallback, e.g. `f"{self.lims_base_url}/Boards/Meetings/{item['Abbreviation']}"`.

### 3. `meetingDate` may be `None`
**File:** `city_scrapers/mixins/minn_city.py:92`

```python
meeting_date = item.get("meetingDate", "")[:10]
```

`.get("meetingDate", "")` returns `""` only when the key is missing. If LIMS returns `"meetingDate": null` (which it sometimes does for unscheduled rows), the slice will raise `TypeError`. Use `(item.get("meetingDate") or "")[:10]`.

### 4. `marked_agenda_path` override is applied to **all** attachment endpoints, not just the one it belongs to
**File:** `city_scrapers/mixins/minn_city.py:71-72`

```python
spider_path_override = getattr(self, "marked_agenda_path", None)
resolved_path = spider_path_override or endpoint["marked_agenda_path"]
```

For `MinnCharCoSpider` the override is `"MarkedAgenda"`. When that spider hits the `Jobs/PublicBoardMeetingsPagedList` endpoint, the per-endpoint default (`Board/MarkedAgenda`) is shadowed by the spider-wide override. This happens to be fine for Charter because Charter only lives in one endpoint — but the design is brittle: as soon as an agency with an override appears in more than one endpoint, links will get wrong URLs. Consider scoping the override per-endpoint (e.g. `marked_agenda_paths = {"CityCouncil/...": "MarkedAgenda"}`).

---

## 🟡 Design / Maintainability

### 5. Attachment data is fetched 41× per cron
Each of the 41 spiders independently issues all three `*PagedList` POST requests (with `length=3000`). The responses are largely identical across spiders — only the `committee_id` filter differs client-side. This is ~123 redundant attachment POSTs per run plus 41 calendar GETs.

If you cannot share state across spider processes, at minimum acknowledge this in the PR description; it dwarfs the previous request volume. A future improvement would be a single combined "Minneapolis" spider that yields meetings for all committees in one crawl.

### 6. No pagination for attachment responses
`length: "3000"` is hard-coded. With a 4-year backfill window plus large committees (City Council, Planning Commission), 3000 may be insufficient. Silently truncating attachments means meetings will appear without their links. Either raise this drastically, page through `totalRowsCount`, or add an assertion that warns when `len(data["data"]) >= 3000`.

### 7. Dead-code `abbreviation` plumbing
**File:** `city_scrapers/mixins/minn_city.py:48, 60-66`

`abbreviation = None` is declared on the mixin and never overridden by any spider config. The `if self.abbreviation:` branch and the `?abbreviation=...` query string are therefore always no-ops. Either wire it up (some endpoints can be pre-filtered server-side) or drop it.

### 8. Unused `category_label` config key
Only `MinnAuditCoSpider` carries `"category_label": "Audit Committee Meeting"`. Nothing in the mixin reads this attribute. It will quietly land on the class as a meaningless attribute. Drop it or document its intended use.

### 9. Single-letter variable shadows `1`
**File:** `city_scrapers/mixins/minn_city.py:227`

```python
agenda = next((l["href"] for l in links if l.get("title") == "Agenda"), None)
```

`l` is a flake8/PEP8 ambiguous-name violation (E741). Rename to `link`.

### 10. Status `text` is just `"cancel"`
**File:** `city_scrapers/mixins/minn_city.py:251`

```python
status_str = "cancel" if item["Cancelled"] else ""
meeting["status"] = self._get_status(meeting, text=status_str)
```

This relies on `_get_status` doing a substring scan for cancellation keywords. It works but reads worse than the previous `"Meeting is cancelled"`. A short comment or a module-level constant (`CANCELLED_HINT = "cancelled"`) would make the intent obvious.

### 11. Pre-existing but worth flagging: wrong timezone
`timezone = "America/North_Dakota/Beulah"` — Minneapolis is `America/Chicago`. Not introduced by this PR, but you’re now touching this line; consider fixing it here.

---

## 🟢 Tests

The new pytest-based suite is a clear improvement: it exercises real fixture data and verifies the link-stitching across multiple agencies. Two regressions to flag:

### 12. Lost coverage for classification branches
The previous test exercised `BOARD`, `COMMITTEE`, `CITY_COUNCIL`, and `NOT_CLASSIFIED`. The replacement only covers the three calendar items, which yield `COMMISSION` and `BOARD`. Add tiny synthetic-`item` tests for the remaining branches so the classifier stays covered.

### 13. `_request_attachment_endpoint` is tested but `_request_primary_calendar` is not
Worth a quick assertion that the calendar URL contains the right `committee_id` and `meeting_type` query params, since those are the only things distinguishing agencies in that request.

### 14. Stale fixture caveat
`@freeze_time("2026-05-06")` only freezes time at call sites that use `datetime.now()` at runtime. Because the mixin computes `today` at **class definition time** (see Bug #1), `freeze_time` won’t affect `from_date`/`to_date` if the module was imported before the decorator activates. Once Bug #1 is fixed, add a test asserting the calendar URL contains the frozen `from_date` and `to_date` values.

---

## Nits

- `_parse_attachment_links`: building the report URL with `.replace(" ", "-")` is fine but doesn’t URL-encode other characters (parens, commas, accents). Consider `urllib.parse.quote` for robustness.
- The big `attachment_formdata` blob with `columns[0][data]` etc. mimics a DataTables request. A short comment explaining why those fields are required would help the next maintainer.
- `spider_configs` in `minn_city.py` could move to its own module (`minn_city_configs.py`) so the dynamic-spider plumbing isn’t buried among 300+ lines of config dicts.
- `_parse_source(self, links)` changing signature from `(item)` to `(links)` is a silent break for any external subclass. Low risk in this repo but worth a CHANGELOG note if anything outside the repo extends `MinnCityMixin`.

---

## Verdict

**Request changes** — the import-time date freezing (Bug #1), the generic-source-URL regression (Bug #2), and the `meetingDate=None` crash (Bug #3) should be fixed before merge. The rest are quality issues that can be addressed in follow-ups.
