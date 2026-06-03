# city-scrapers Claude skills

Claude Code skills for working with the [City-Bureau/city-scrapers](https://github.com/City-Bureau/city-scrapers) family of repos (Scrapy projects that feed Documenters.org).

Drop the contents of any of these folders into your project's `.claude/skills/` directory (or `~/.claude/skills/` for global) to make them invocable via the Skill tool.

## Skills

| Skill | What it does |
|---|---|
| [`code-review/`](./code-review/) | Code-review a scraper PR. Checks output JSON, spider conventions, Scrapy-specific anti-patterns, test coverage. Saves the review to `PR<number>_REVIEW.md`. |
| [`merge-staging/`](./merge-staging/) | Merge every open non-dependabot, non-draft PR into the `staging` branch. Runs lint + tests after each merge, pushes when green. |
| [`refresh-staging-scraped-data/`](./refresh-staging-scraped-data/) | Wipe Azure staging blobs, re-run the staging scrape, and re-trigger the Documenters meeting-feed import via Heroku CLI. Includes pre-flight checks (verify `program.meetings_feed_endpoint` points at the staging container, not prod), a scoped-delete variant (refresh only the N spiders that changed), and a `Meeting`-model schema reference. Heroku app name is a `<your-staging-app>` placeholder — replace with your env's actual staging app, or thread it through a shell variable. |
| [`setup-staging-workflow/`](./setup-staging-workflow/) | Scaffold the staging environment in a `city-scrapers-*` fork that doesn't have one yet: writes `city_scrapers/settings/staging.py` and `.github/workflows/staging.yml` mirroring the minimal `city-scrapers-coloh` pattern, audits GitHub Actions secrets via `gh secret list`, and walks the off-repo follow-ups (create `staging` branch, create Azure staging container). |

## How invocation works

A skill file is a Markdown doc with YAML frontmatter:

```markdown
---
name: skill-name
description: One-line what it does
---

Step-by-step prompt instructions for Claude…
```

When the skill lives at `.claude/skills/<name>/SKILL.md`, Claude Code surfaces it under that name. You invoke it with `/<name>` from the chat input.

## Source

These were extracted from the project-local `.claude/skills/` directories of
several `city-scrapers-*` repos (all three skills were byte-identical across
the repos — they're a shared baseline). Genericized for public sharing: the
staging Heroku app name has been replaced with `<your-staging-app>` placeholders
so this bundle doesn't pin to a specific deployment.
