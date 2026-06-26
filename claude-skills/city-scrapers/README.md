# city-scrapers Claude skills

Claude Code skills for working with the [City-Bureau/city-scrapers](https://github.com/City-Bureau/city-scrapers) family of repos (Scrapy projects that feed Documenters.org).

Drop the contents of any of these folders into your project's `.claude/skills/` directory (or `~/.claude/skills/` for global) to make them invocable via the Skill tool.

## Skills

### Authoring & maintaining spiders

> Designing a spider from just a URL? Start with the `spider-explorer` subagent
> in [`../../claude-agents/`](../../claude-agents/), then come back to `build-spider`.

| Skill | What it does |
|---|---|
| [`build-spider/`](./build-spider/) | Scaffold a new spider end-to-end — agency URL → spider class → frozen test fixture → unit test → first successful crawl. |
| [`fix-spider/`](./fix-spider/) | Diagnose and fix a spider producing 0 items, throwing errors, or scraping wrong data. |
| [`validate-spider-output/`](./validate-spider-output/) | Run a spider locally and validate its JSON output against the City Scrapers schema. |
| [`audit-spider-health/`](./audit-spider-health/) | Audit which spiders are healthy vs broken by parsing recent GitHub Actions cron logs — per-spider item counts, 4xx/5xx rates, regressions. |
| [`code-review/`](./code-review/) | Code-review a scraper PR. Checks output JSON, spider conventions, Scrapy-specific anti-patterns, test coverage. Saves the review to `PR<number>_REVIEW.md`. |

### Staging & release pipeline

| Skill | What it does |
|---|---|
| [`merge-staging/`](./merge-staging/) | Merge every open non-dependabot, non-draft PR into the `staging` branch. Runs lint + tests after each merge, pushes when green. |
| [`setup-staging-workflow/`](./setup-staging-workflow/) | Scaffold the staging environment in a fork that doesn't have one: writes `city_scrapers/settings/staging.py` and `.github/workflows/staging.yml` (the minimal `city-scrapers-coloh` pattern), audits GitHub Actions secrets, walks the off-repo follow-ups (create `staging` branch + Azure container). |
| [`setup-refresh-staging/`](./setup-refresh-staging/) | Heavier sibling of `setup-staging-workflow`: wires the full auto-merge → crawl → refresh-db staging pipeline (`refresh-staging.yml` workflow + GitHub `staging` environment + secrets + protection rules). |
| [`refresh-staging-scraped-data/`](./refresh-staging-scraped-data/) | Wipe Azure staging blobs, re-run the staging scrape, and re-trigger the Documenters meeting-feed import via Heroku CLI. Includes pre-flight checks, a scoped-delete variant, and a `Meeting`-model schema reference. Heroku app name is a `<your-staging-app>` placeholder. |
| [`release-scraper-prod/`](./release-scraper-prod/) | Release a single scraper to production — merge PR to `main`, refresh the feed, clean the prod DB (no-assignment meetings only), re-import. |

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
several `city-scrapers-*` repos — each skill was byte-identical across the repos
(a shared baseline), with the newest variant taken where a fork had drifted.
Genericized for public sharing: the staging Heroku app name is a
`<your-staging-app>` placeholder so this bundle doesn't pin to a specific
deployment. (`release-scraper-prod` and `setup-refresh-staging` reference the
real prod/staging app names by design — they're operational runbooks, and app
names are not secrets.)
