---
name: validate-spider-output
description: Run a spider locally and validate the JSON output against the City Scrapers schema. Use after editing a spider, before opening a PR, or when user says "validate <spider>", "check spider output", "is this spider's data correct".
---

## What this does

Runs `scrapy crawl <spider> -O /tmp/<spider>.json`, then validates the output against:
1. The `city_scrapers_core` schema (`scrapy validate <spider>`).
2. Required fields: `title`, `start`, `location`, `links`, `status`, `classification`, `source`, `id`.
3. Data sanity heuristics (dates plausible, URLs absolute, IDs unique).

## Process

### Step 1 — Run the spider

```bash
SPIDER=<spider>  # e.g. oma_mud
pipenv run scrapy crawl "$SPIDER" -O "/tmp/$SPIDER.json" -L INFO 2>&1 | tee "/tmp/$SPIDER.log"

# Check it actually produced items
test -s "/tmp/$SPIDER.json" || { echo "Empty output — spider failed"; exit 1; }
jq 'length' "/tmp/$SPIDER.json"
```

### Step 2 — Schema validation

```bash
pipenv run scrapy validate "$SPIDER" 2>&1 | tail -20
```

city_scrapers_core's validator enforces:
- All required Meeting fields present
- `status` ∈ {tentative, passed, cancelled, confirmed}
- `classification` ∈ predefined set
- `links` is list of `{title, href}` dicts
- `location` has `name` and/or `address`

If validate fails, fix before proceeding.

### Step 3 — Data sanity (Python one-liner)

```bash
python3 <<'PYEOF'
import json, sys
from collections import Counter
from urllib.parse import urlparse

data = json.load(open(f"/tmp/{SPIDER}.json")) if False else \
       [json.loads(l) for l in open(f"/tmp/$SPIDER.json")]
# (handle both single-array and JSONL formats above; use the one your settings emit)

print(f"items: {len(data)}")

# Unique IDs
ids = [d.get("id","") for d in data]
dup = [(i,c) for i,c in Counter(ids).items() if c > 1]
if dup: print(f"❌ DUP IDs: {dup[:5]}")
else: print("✓ unique IDs")

# Title sanity
empty_titles = [d for d in data if not d.get("title")]
if empty_titles: print(f"❌ {len(empty_titles)} empty titles")
else: print("✓ all titles present")

# Date sanity (no 1900s or 2099s)
from datetime import datetime
bad_dates = [d for d in data if isinstance(d.get("start"), str) and
             not (datetime.fromisoformat(d["start"]).year >= 2020)]
if bad_dates: print(f"❌ {len(bad_dates)} suspect dates")
else: print("✓ dates plausible")

# Link URLs absolute
bad_links = [d for d in data for l in (d.get("links") or [])
             if not urlparse(l.get("href","")).scheme]
if bad_links: print(f"❌ {len(bad_links)} relative URLs in links")
else: print("✓ all links absolute")

# Classification distribution
print("classifications:", Counter(d.get("classification") for d in data).most_common(5))

# Status distribution
print("status:", Counter(d.get("status") for d in data).most_common())

# Sample first item
print("\n--- sample item ---")
print(json.dumps(data[0], indent=2, default=str)[:1000])
PYEOF
```

### Step 4 — Cross-check 3 items against the source

For random sampling, pick 3 items and verify against the live source page:

```bash
python3 -c "
import json, random
data = [json.loads(l) for l in open('/tmp/$SPIDER.json')]
random.seed(1)
for item in random.sample(data, min(3, len(data))):
    print(item['title'])
    print(f'  start: {item[\"start\"]}')
    print(f'  source: {item[\"source\"]}')
    print()
"
```

Then `WebFetch` each `source` URL and confirm the title + date match.

### Step 5 — Verdict

Pass:
- ✓ scrapy validate clean
- ✓ unique IDs
- ✓ all required fields present
- ✓ dates plausible
- ✓ URLs absolute
- ✓ 3 sample items match source

Fail any of these → return to `/fix-spider` (or `/build-spider` if mid-build).

## Quick mode (for `--quick` flag-style invocation)

If user wants just a smoke test (not full audit), short-circuit to:

```bash
pipenv run scrapy crawl <spider> -O /tmp/out.json 2>&1 | tail -5
jq 'length' /tmp/out.json
jq '.[0]' /tmp/out.json
pipenv run scrapy validate <spider>
```

Done in <30s. Use for incremental dev, not for pre-PR validation.

## Anti-patterns

- ❌ Validating against the test fixture rather than a live crawl — fixtures don't catch live regressions.
- ❌ Skipping `scrapy validate` because tests pass — schema validation catches different issues.
- ❌ "Look at first item, looks good" without sampling random items — top items often have richer data than the long tail.
