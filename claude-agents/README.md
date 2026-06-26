# Claude Code subagents

Lightweight `Agent`-tool subagents (the `.claude/agents/*.md` kind) used while
working on the City-Bureau projects. Each file is a single Markdown doc with
YAML frontmatter (`name`, `description`, `tools`, `model`); Claude Code surfaces
it as a delegate the main agent can hand focused work to.

These are distinct from [`../ai-agents/`](../ai-agents/), which holds the heavier
`launchd`-scheduled headless `claude -p` flows. The subagents here run *inside* a
session, not on a schedule.

Drop a file into `.claude/agents/` (project) or `~/.claude/agents/` (global) to
make it available.

## city-scrapers

| Subagent | Model | What it does |
|---|---|---|
| [`spider-explorer`](./city-scrapers/spider-explorer.md) | sonnet | Explore an agency's meetings page to design a spider strategy (page type, base class, selectors, anti-bot signals). Use *before* writing spider code when you only have a URL. |
| [`fixture-curator`](./city-scrapers/fixture-curator.md) | haiku | Download, trim, and freeze a test fixture (static, JS-rendered via Playwright, or JSON API), keeping fixture work out of the parent's context. |
| [`spider-debugger`](./city-scrapers/spider-debugger.md) | sonnet | Investigate a spider producing wrong/zero items in production — pulls cron logs, diffs against working runs, returns a fix *strategy*. |
| [`spider-reviewer`](./city-scrapers/spider-reviewer.md) | sonnet | Deep, Scrapy-specific code review of a spider PR: output-schema validation, fixture sanity, `city_scrapers_core` idioms. |

## documenters

| Subagent | Model | What it does |
|---|---|---|
| [`dramatiq-reviewer`](./documenters/dramatiq-reviewer.md) | sonnet | Review Dramatiq actor changes (`*/tasks.py`) — retries, idempotency, time/queue config, notification gotchas. Returns a focused punch list. |
| [`migration-reviewer`](./documenters/migration-reviewer.md) | sonnet | Review Django migrations — reversibility, `RunPython` safety, numbering vs `development`, operational risk on large tables. |
| [`heroku-log-auditor`](./documenters/heroku-log-auditor.md) | sonnet | Triage Heroku logs (`documenters-stg` / `documenters-prod`) for Dramatiq failures, Postgres connection exhaustion, Azure Blob timeouts, rate-limit errors. |
