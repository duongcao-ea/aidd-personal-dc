# Worked example — DOC-XXXX

Source context (what the user provided):

> `<partner-contact>` (`<partner>`) emailed: documenters still hitting > 100 req/min on
> assets.documentcloud.org despite DOC-YYYY throttle. UA `Documenters/1.0`,
> 6,000 rate-limited in 24h. Investigation showed `RATE_LIMITER` only wraps
> `update_document_content` actor, not the two Contextualizer call sites
> (`utils.py:39` and `utils.py:99`).

Drafted output:

```
Title: Throttle Contextualizer DocumentCloud fetches under 100/min

## Context

After DOC-YYYY throttled `update_document_content`, `<partner>` (`<partner-contact>`) still
reports 6,000+ rate-limited (HTTP 429) requests / 24h from documenters
(UA `Documenters/1.0`), all hitting `assets.documentcloud.org/documents/<id>/<slug>.txt`.
Traffic is bursty — > 100 req/min during spikes (manager batch-creates
assignments → fan-out of brief pre-generations → parallel Dramatiq workers).

## Root cause

`RATE_LIMITER` (84 req/min, 7 per 5s window) only wraps the
`update_document_content` actor (`documents/tasks.py:495`). Two Contextualizer
paths call `Document.get_content()` → `DocumentCloud.get_content()` →
raw HTTP GET on the `.txt` URL **without acquiring the limiter**:

- `documenters/contextualizer/agentic/utils.py:39` — `get_document_context()`
  (`extract_nuggets` actor; 1 call per document upload)
- `documenters/contextualizer/agentic/utils.py:99` — `load_source_documents_text()`
  fallback (`generate_briefing` actor; looped over 5–30 docs per briefing;
  the dominant burst path)

`generate_briefing` fires on auto-pregeneration (every Assignment create),
user "Generate brief" clicks, and `reconcile_stuck_briefings`. Multiple
Dramatiq workers run pipelines in parallel — unlimited fan-out trivially
exceeds 100/min.

## Fix

Move `RATE_LIMITER.acquire()` from the actor wrapper into
`DocumentCloud.get_content()` itself (`documenters/documents/documents.py:732`).
Every caller — current and future — inherits throttling without per-call-site
edits. Drop the now-redundant wrapper in `update_document_content`.

## Acceptance criteria

- [ ] `DocumentCloud.get_content()` acquires `RATE_LIMITER` before issuing
      the HTTP GET, releases on success and exception.
- [ ] `update_document_content` no longer wraps `_save_document_content`
      (limiter is one level deeper now; double-acquire would deadlock).
- [ ] Unit test: concurrent `get_content()` from multiple workers serialize
      under the limiter (mirror the existing rate-limit test in `test_tasks.py`).
- [ ] Existing `extract_nuggets` and `load_source_documents_text` tests pass.
- [ ] Production: 24h after deploy, `<partner>` 429 count from `Documenters/1.0`
      drops to ~0 (verify with `<partner-contact>` or outbound log).
- [ ] Daily cron `load_missing_document_content` still completes within its
      window.

## Out of scope

- Why `Document.content` is empty for old docs (`<partner-contact>` cited 2018/2024 files
  that should have been pre-warmed). Track separately if it recurs after fix.
- AWS WAF inbound rate-limit (separate work).
```

Why this works:

- **Title** names subsystem (`Contextualizer`), action (`Throttle`), and target
  (`DocumentCloud fetches`) plus the threshold (`100/min`) — all greppable.
- **Context** leads with the concrete number (`6,000+`) and the reporter
  (`<partner-contact>`) — anyone triaging knows immediately how bad and who to follow up with.
- **Root cause** cites `file:line` for both leak sites; reviewers can verify
  without re-running the investigation.
- **Fix** explains *why this shape* (cover future callers automatically) — not
  just *what* to change.
- **AC** is concrete and observable, including a production verification step
  (`<partner>` 429 metric) and a regression check (daily cron throughput).
- **Out of scope** preempts the "while you're at it" question without inviting it.
