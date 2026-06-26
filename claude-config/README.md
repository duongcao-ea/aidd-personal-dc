# Claude Code project config

The rest of each project's `.claude/` setup — everything that isn't a skill,
subagent, or slash command: the permission/hook `settings.json`, the hook
scripts they wire up, the reference docs agents lean on, and (documenters) a
status line. Each subfolder mirrors that project's `.claude/` layout, so you can
copy a file straight back to `<repo>/.claude/<same path>`.

> **Not included:** `settings.local.json` (machine-local permission overrides),
> `skills.zip` (a redundant archive — the skills live unpacked under
> [`../claude-skills/`](../claude-skills/)), and run-time lock files.

## city-scrapers

Uniform across all `city-scrapers-*` forks.

| Path | What it is |
|---|---|
| [`city-scrapers/settings.json`](./city-scrapers/settings.json) | Read-only-by-default permission allowlist (git/gh/pipenv/scrapy/az read ops), a deny-list for destructive ops (push to main, `rm -rf`, blob delete, `gh pr merge`…), and a PostToolUse hook that formats Python after every edit. |
| [`city-scrapers/hooks/format-python.sh`](./city-scrapers/hooks/format-python.sh) | The PostToolUse formatter the settings reference. |
| [`city-scrapers/docs/ARCHITECTURE.md`](./city-scrapers/docs/ARCHITECTURE.md) | How a city-scrapers project is wired (Scrapy + `city_scrapers_core`). |
| [`city-scrapers/docs/SPIDER_PATTERNS.md`](./city-scrapers/docs/SPIDER_PATTERNS.md) | Recurring spider shapes and the idioms to reach for. |
| [`city-scrapers/docs/TROUBLESHOOTING.md`](./city-scrapers/docs/TROUBLESHOOTING.md) | Common spider failures and how to diagnose them. |

## documenters

| Path | What it is |
|---|---|
| [`documenters/settings.json`](./documenters/settings.json) | Permission allowlist (git/gh/make/manage.py), a force-push deny-list, three hooks, the status line, and `superpowers` plugin enablement. |
| [`documenters/hooks/format_py_after_edit.sh`](./documenters/hooks/format_py_after_edit.sh) | PostToolUse: black + isort the edited file (skips migrations/vendor). |
| [`documenters/hooks/block_direct_lint_tools.sh`](./documenters/hooks/block_direct_lint_tools.sh) | PreToolUse: block bare `pytest`/`black`/`isort`/`flake8` — go through `make`. |
| [`documenters/hooks/session_start_context.sh`](./documenters/hooks/session_start_context.sh) | SessionStart: inject branch / ticket / dirty-count / WIP-markdown context. |
| [`documenters/statusline.sh`](./documenters/statusline.sh) | Status line — branch · ticket · dirty count · model · ctx% · cost. |
