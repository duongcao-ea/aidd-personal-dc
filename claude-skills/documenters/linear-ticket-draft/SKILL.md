---
description: Draft a Linear ticket (title + description) for documenters work, following the project's KISS + Agile convention. Use when the user asks to "write a Linear issue", "draft a ticket title and description", or wants help shaping a freshly-discovered bug/task into Linear-ready copy. Distinct from `linear-ticket`, which FETCHES an existing ticket.
allowed-tools: Read, Grep, Glob, Bash(git log:*)
argument-hint: <short context — what was found / what needs doing>
---

# Draft a Linear ticket (KISS + Agile)

Produce a Linear-ready title + description from a short context blurb. Output is meant to be pasted directly into Linear — no preamble, no follow-up questions in the body itself.

## Title rules

- **Imperative present tense** ("Throttle …", "Add …", "Fix …", "Drop …") — not "Throttling" / "Throttled".
- **Under 70 characters.** If longer, cut adjectives, not nouns.
- **Concrete + specific:** name the subsystem and the action, not generic verbs.
  - ❌ "Improve performance"
  - ❌ "Fix bug in documents"
  - ✅ "Throttle Contextualizer DocumentCloud fetches under 100/min"
- **Greppable:** include the symbol or path the team will search for (`RATE_LIMITER`, `get_content`, `extract_nuggets`, etc.).
- **No prefix** like `[BUG]` / `[FEATURE]` in the Linear title — Linear handles labels separately. (The `[f] DOC-XXXX:` prefix belongs in *commit* titles, not ticket titles.)

Offer 2–3 title options when the chosen verb / framing isn't obvious, and let the user pick. Don't pick silently.

## Description structure

Five sections, in this order. Skip a section only if it would be empty.

```markdown
## Context

<1–2 paragraphs: what's happening, with concrete evidence (numbers, error
messages, who reported it). Cite paths only if needed to ground the problem.>

## Root cause

<Technical cause in file:line form. Trace the call path if it's non-obvious.
If you don't know yet, write "Unknown — investigation required" and STOP —
don't fabricate a cause.>

## Fix

<What changes, and why this shape (not other shapes). Keep it to the
minimum reasonable change.>

## Acceptance criteria

- [ ] Testable bullet 1.
- [ ] Testable bullet 2.
- [ ] Production verification step (a metric / log line / behavior to confirm).
- [ ] Regression check on adjacent code that could break.

## Out of scope

- <Adjacent things the investigation surfaced but this ticket won't touch —
  short justification each. Helps reviewers, prevents scope creep.>
```

## KISS rules for the body

- **Evidence beats narrative.** "`<partner>` reports 6,000+ HTTP 429 / 24h" >
  "we're getting rate-limited a lot."
- **Cite `file:line`** for every claim about the code, so future-you can re-verify.
- **No code blocks longer than ~10 lines.** If a diff is long, link the PR.
- **No "as a user, I want…" boilerplate** — this is internal engineering work,
  not a sales doc. Agile here means "small, testable, shippable", not "Gherkin".
- **Acceptance criteria must be observable** — "improved performance" is not
  an AC; "p95 < 200ms in CloudWatch" is.
- **Out of scope is mandatory** for any ticket touching shared infra — the
  investigation always surfaces 2–3 adjacent issues, naming them prevents
  scope creep and signals the author thought about it.

## Anti-patterns

- Don't write a wall of Slack-paste context. Summarize.
- Don't restate the title in the first line of Context.
- Don't include "estimated effort" or "priority" — Linear handles those as fields.
- Don't include Claude attribution or "co-authored by" in the body.
- Don't add screenshots unless they're load-bearing (UI bug, dashboard reading).
- Don't put the Linear URL inside the body — Linear adds it itself.

## Output shape

Print to chat as a single markdown block ready to paste:

```
Title: <one line>

<description body>
```

If the user offered a draft title (often vague), explicitly list 2–3 stronger
alternatives in a small table with char counts and trade-offs, then propose one.
Don't lecture them — just give better options.

## Reference example

See [`./example.md`](./example.md) for a worked example (Throttle Contextualizer
DocumentCloud fetches).
