# Claude skills inventory — documenters + scrapers + global

All skills you can call via the `Skill` tool, grouped by where they live and when they're active. Last updated 2026-06-04.

---

## A. Built-in (always available, every project)

These ship with the Claude Code harness — no install needed.

| Skill | What it does |
|---|---|
| `update-config` | Edit `settings.json` (permissions, env vars, hooks) |
| `keybindings-help` | Customize `~/.claude/keybindings.json` |
| `simplify` | Review changed code for reuse/quality, fix issues |
| `less-permission-prompts` | Scan transcripts → propose project `.claude/settings.json` allowlist |
| `loop` | Run prompt/command on recurring interval |
| `schedule` | Manage remote scheduled agents (CCR triggers at claude.ai/code/scheduled) |
| `claude-api` | Build/debug/optimize Anthropic SDK apps, migrate between Claude versions |
| `init` | Initialize a new `CLAUDE.md` for a codebase |
| `review` | Lighter PR review |
| `security-review` | Security review of pending changes on current branch |

---

## B. Global user skills (`~/.claude/skills/`)

Active in every project regardless of cwd.

| Skill | Description |
|---|---|
| `code-review` | Review code for bugs, style, improvements (Scrapy-flavored examples but general core) |
| `release-scraper-prod` | Release a single scraper to prod — merge PR to main, refresh feed, clean prod DB, re-import |
| `setup-staging-workflow` | Set up staging GitHub Actions workflow + Scrapy staging settings in a city-scrapers repo |

---

## C. Enabled plugins (`~/.claude/settings.json` → `enabledPlugins`)

| Plugin | Provides |
|---|---|
| `code-review@claude-plugins-official` | The `code-review:code-review` skill — code review a pull request |

Cached but **not enabled** (available to install via `claude plugin install`):

| Marketplace plugin | Provides |
|---|---|
| `plugin-dev` | command-development, skill-development, plugin-settings, plugin-structure, hook-development, mcp-integration, agent-development |
| `mcp-server-dev` | build-mcp-server, build-mcp-app, build-mcpb |
| `claude-md-management` | claude-md-improver |
| `claude-code-setup` | claude-automation-recommender |
| `frontend-design` | frontend-design |
| `hookify` | writing-rules |
| `claude-opus-4-5-migration` | migration helper |
| `playground` | playground |
| `cwc-makers` | m5-onboard, cardputer-buddy |

---

## D. Per-project — **city-scrapers-** repos

Active when cwd is inside a `city-scrapers-*` repo. **Master copies** live in `aidd-personal-dc/claude-skills/city-scrapers/`; project repos get them via sync (or copied into `.claude/skills/`).

| Skill | Description |
|---|---|
| `merge-staging` | Merge open PRs into staging branch (excludes dependabot) |
| `refresh-staging-scraped-data` | Merge PRs → clean Azure → reset DB → import |
| `release-scraper-prod` | Same as global (mirrored) |
| `setup-staging-workflow` | Same as global (mirrored) |
| `code-review` | City-scrapers flavored review |
| `audit-spider-health` | Audit which spiders healthy vs broken via GH Actions cron logs |
| `build-spider` | Scaffold a new spider end-to-end (URL → class → fixture → test → first crawl) |
| `fix-spider` | Diagnose and fix a broken spider (0 items, errors, wrong data) |
| `validate-spider-output` | Run a spider locally + validate JSON against City Scrapers schema |

Note: `audit-spider-health`, `build-spider`, `fix-spider`, `validate-spider-output` are project-resident only (not in `aidd-personal-dc/claude-skills/` — they were created directly in city-scrapers-minn).

---

## E. Per-project — **documenters** repo (`documenters/.claude/skills/`)

Active only when cwd is inside `~/duong.cao/documenters`.

| Skill | Description |
|---|---|
| `agency-debug` | Inspect Agency state across Meeting/Document/Assignment FKs — surfaces duplicates, dangling FKs, recurring-pattern mismatches |
| `commit-doc` | Stage + commit using `[f] DOC-XXXX:` convention |
| `linear-ticket` | Fetch Linear DOC-XXXX ticket (title, body, AC, state, URL) — falls back to git log if Linear MCP disconnected |
| `merge-development` | Merge latest `development` into feature branch, auto-renumber colliding migrations |
| `pr-review-doc` | Review a documenters PR using project lens (senior architect "is there a simpler way?", dead code, dramatiq/migration gotchas) → write to `PR<N>_REVIEW.md` |

---

## F. Custom slash commands (not skills, but adjacent)

These live in `~/.claude/commands/` and are invoked with `/<name> <args>`. Global, work in every project.

| Command | Where | Purpose |
|---|---|---|
| `/pr-review` | `~/.claude/commands/pr-review.md` | Maximal-tech PR review: parallel Explore agents, GitHub/Linear MCP, conditional skill chaining (security-review/simplify), structured verified-at-source markdown → writes to `PR<N>_REVIEW.md` in cwd |

---

## Count summary

| Source | Active everywhere | Active in city-scrapers-* only | Active in documenters only | Cached/available to install |
|---|---:|---:|---:|---:|
| Built-in | 10 | — | — | — |
| Global user skills | 3 | — | — | — |
| Enabled plugins | 1 | — | — | — |
| `aidd-personal-dc/claude-skills/city-scrapers/` (mirrored to project) | — | 5 | — | — |
| Project-resident `city-scrapers-minn/.claude/skills/` | — | 4 (build/fix/validate/audit) | — | — |
| `documenters/.claude/skills/` | — | — | 5 | — |
| Marketplace plugins (not installed) | — | — | — | ~15 |
| Custom slash commands | 1 (`/pr-review`) | — | — | — |

**Total available right now:**
- In any session: **14** (10 built-in + 3 global skills + 1 plugin skill + 1 slash command — though slash commands are technically not skills, included for completeness)
- In a city-scrapers-* session: **+9** (5 mirrored + 4 project-resident)
- In documenters session: **+5**

---

## Source-of-truth map

```
~/.claude/skills/                                    # global, lives forever
~/.claude/commands/pr-review.md                      # global slash command
~/.claude/settings.json                              # enabledPlugins + permissions

aidd-personal-dc/claude-skills/city-scrapers/        # source for scraper skills
  ↓ (synced/copied)
city-scrapers-*/.claude/skills/                      # per-project active

documenters/.claude/skills/                          # documenters-only
documenters/.claude/settings.local.json              # documenters allowlist
```

---

## Known gaps / housekeeping

1. **`city-scrapers-minn/.claude/skills/` is empty** — the build/fix/validate/audit-spider skills referenced in recent system reminders aren't in the filesystem at that path. They may have been moved or were never persisted. Worth a check.
2. **`aidd-personal-dc/claude-skills/city-scrapers/` has 5 skills** but city-scrapers project repos need them deployed via `.claude/skills/`. Some repos have them, some don't — no sync mechanism in place.
3. **Documenters skills aren't mirrored to `aidd-personal-dc/claude-skills/`** — they live only in the documenters repo. If the repo is re-cloned without `.claude/`, they're lost. Consider mirroring under `aidd-personal-dc/claude-skills/documenters/` for backup.
4. **Plugin `code-review@claude-plugins-official` ships only one skill** (`code-review:code-review`) — overlaps with the global `code-review` skill. Probably safe to keep both since they live in different namespaces.
5. **Marketplace plugins are cached but unused.** `plugin-dev`, `mcp-server-dev`, `claude-md-management` could be useful — install if relevant.

---

## Quick recall

- **"I want to review a PR"** → `/pr-review` (global slash command, deepest) OR `pr-review-doc` skill (documenters only, project lens) OR `code-review`/`review` (lighter)
- **"I want to commit"** → `commit-doc` in documenters; manual elsewhere
- **"I want to start work on a Linear ticket"** → `linear-ticket` (documenters only)
- **"I want to fix a broken scraper"** → `fix-spider` (city-scrapers only)
- **"I want to set up staging for a new scraper"** → `setup-staging-workflow`
- **"I want to release a scraper to prod"** → `release-scraper-prod`
- **"I want to schedule a recurring task"** → `schedule` (remote agent) or `loop` (local)
- **"I want to clean up settings.json"** → `update-config`
- **"I'm getting too many permission prompts"** → `less-permission-prompts`
