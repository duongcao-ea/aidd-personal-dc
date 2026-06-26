---
description: Inspect Agency state across Meeting / Document / Assignment FKs for a given slug, scraper_name, or ID — surfaces duplicate Agency rows, dangling FKs, recurring-pattern mismatches, and stale Basecamp links. Use when debugging scraper duplicates, missing meetings, or Agency consolidation issues.
allowed-tools: Bash(python manage.py shell:*), Bash(python manage.py showmigrations:*), Bash(grep -rn agency:*)
argument-hint: [agency_slug | scraper_name | agency_id]
---

# Agency state inspection

Documenters has known race conditions around Agency creation (`meetings/builders.py:233-250`) and `programs.set()` overwriting manual assignments (`meetings/builders.py:256`). This skill encodes the recurring inspection pattern so debugging is reproducible.

## Step 1 — locate the Agency

Run a `manage.py shell -c` one-liner. Match by all three keys to catch dupes:

```bash
python manage.py shell -c "
from documenters.meetings.models import Agency
qs = Agency.objects.filter(slug__iexact='$ARGUMENTS') | Agency.objects.filter(scraper_names__icontains='$ARGUMENTS') | Agency.objects.filter(name__icontains='$ARGUMENTS')
for a in qs.distinct():
    print(f'{a.id}\t{a.slug}\t{a.scraper_names}\t{a.name}\tprograms={list(a.programs.values_list(\"slug\", flat=True))}')
"
```

If >1 row returns for the same logical agency → duplicate from race condition. Report the IDs.

## Step 2 — FK fanout

For each Agency ID found:

```bash
python manage.py shell -c "
from documenters.meetings.models import Agency, Meeting
from documenters.assignments.models import Assignment
from documenters.documents.models import Document
for aid in [<IDs>]:
    a = Agency.objects.get(id=aid)
    print(f'--- Agency {aid} ({a.slug}) ---')
    print(f'  Meetings:    {Meeting.objects.filter(agency=a).count()}')
    print(f'  Assignments: {Assignment.objects.filter(agency=a).count()}')
    print(f'  Documents:   {Document.objects.filter(agency=a).count()}')
    print(f'  Recurring:   {a.recurring_meeting_patterns.count() if hasattr(a, \"recurring_meeting_patterns\") else \"n/a\"}')
"
```

This tells you which duplicate is the "real" one (highest fanout) vs the orphan.

## Step 3 — check for the known gotchas

- **Race-condition dupes:** Did Step 1 return >1 Agency for the same scraper_name? That's the `_get_or_create_agency` race. Recommend consolidating via management command, not direct SQL.
- **`programs.set()` overwrite:** Compare `a.programs.all()` against what the scraper passed. If user-assigned programs vanished after a recent scraper run, that's the `set()` bug at `meetings/builders.py:256`.
- **TOCTOU on hard delete:** If meetings vanished unexpectedly, check `meetings/tasks.py:313-324` `_delete_agency_meetings` — there's no `select_for_update`, so a concurrent Assignment write can race.
- **Silent scraper drop:** If meetings stopped flowing in but no error in Sentry → check `import_meeting_json` at `meetings/utils.py:22`. It silently drops when `scraper_name` doesn't match any Agency — only an INFO log.

## Step 4 — propose action, do NOT mutate

This skill is **read-only**. Surface findings; let the user decide whether to:
- Open a fix ticket (DOC-XXXX) and use `plan-to-markdown` for the proposal.
- Run a one-shot consolidation via a custom management command (require review).
- Add a unique constraint migration — `migration-reviewer` subagent should review first.

Never execute `Agency.objects.delete()` or `.update()` from this skill.

## When to use a subagent instead

If the inspection grows beyond 3-4 shell calls (e.g., comparing 5 Agency dupes' full FK fanout, or tracing a scraper run across 100 Meetings), spawn an `Explore` agent to gather and synthesize, not this skill.
