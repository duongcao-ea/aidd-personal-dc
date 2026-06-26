# documenters Claude skills

Claude Code skills for working with the `City-Bureau/documenters` Django app
(the platform that city-scrapers feeds). These live in
`documenters/.claude/skills/` on a working machine; this folder is the
versioned backup / source of truth.

Drop the contents of any folder into your project's `.claude/skills/` directory
to make it invocable via the Skill tool.

## Skills

| Skill | What it does |
|---|---|
| [`agency-debug/`](./agency-debug/) | Inspect Agency state across Meeting / Document / Assignment FKs for a slug, scraper_name, or ID — surfaces duplicate Agency rows, dangling FKs, recurring-pattern mismatches, and stale Basecamp links. |
| [`commit-doc/`](./commit-doc/) | Stage and commit changes following the `[f] DOC-XXXX:` convention. |
| [`linear-ticket/`](./linear-ticket/) | Fetch a Linear ticket (DOC-XXXX) — title, body, AC, state, URL. Falls back to `git log` if the Linear MCP isn't connected. |
| [`linear-ticket-draft/`](./linear-ticket-draft/) | Draft a Linear-ready ticket (title + description) following the project's KISS + Agile convention. Includes a [worked example](./linear-ticket-draft/example.md). Distinct from `linear-ticket`, which *fetches* an existing ticket. |
| [`merge-development/`](./merge-development/) | Merge the latest `development` into the current feature branch, resolving migration-number collisions by renumbering the PR-side migration. |
| [`pr-review-doc/`](./pr-review-doc/) | Review a documenters PR using the project lens (senior-architect "is there a simpler way?", dead code, dramatiq/migration gotchas) → writes to `PR<number>_REVIEW.md`. |
| [`research/`](./research/) | Research a question before answering — parallel codebase exploration + official-docs lookup → writes `RESEARCH_<topic>.md`, then answers with `file:line` citations. |

## How invocation works

A skill file is a Markdown doc with YAML frontmatter:

```markdown
---
name: skill-name
description: One-line what it does
---

Step-by-step prompt instructions for Claude…
```

When the skill lives at `.claude/skills/<name>/SKILL.md`, Claude Code surfaces it
under that name. You invoke it with `/<name>` from the chat input.

## Source & sanitization

Extracted from the project-local `documenters/.claude/skills/` directory. The
`linear-ticket-draft` worked example was sanitized for public sharing: a real
partner contact and organisation were replaced with `<partner-contact>` /
`<partner>` placeholders, and internal ticket IDs with `DOC-XXXX` / `DOC-YYYY`.
