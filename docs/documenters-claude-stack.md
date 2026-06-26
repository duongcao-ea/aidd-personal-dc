# Claude stack — documenters

A consolidated map of every Claude-powered tool currently wired up for the `City-Bureau/documenters` workflow. Last updated 2026-06-04.

---

## At a glance

| Layer | What | Where it lives | How it fires |
|---|---|---|---|
| **Reactive (per-PR)** | Claude PR Assistant — replies to `@claude` mentions | `documenters/.github/workflows/claude.yml` | GitHub event (issue/PR/review comment containing `@claude`) |
| **Daily batch** | Daily PR review agent | `aidd-personal-dc/ai-agents/documenters-pr-review-agent/` | `launchd` 08:30 local |
| **On-demand (interactive)** | `/pr-review` slash command (global) | `~/.claude/commands/pr-review.md` | `/pr-review <PR-url>` in any Claude Code session |
| **On-demand (agentic)** | Issue→PR multi-agent flow | `aidd-personal-dc/ai-agents/documenters-issue-to-pr-agent/` | `./bin/flow.sh new <issue.md>` |
| **Global config** | MCP servers + permissions allowlist | `~/.claude/settings.json`, `~/.claude.json` | Active in every Claude Code session |
| **Artifacts** | Per-PR review markdown | `~/pr-reviews/documenters_PR<N>.md` | Output of daily agent + slash command |

---

## 1. Reactive — Claude PR Assistant (in-repo)

**File:** `documenters/.github/workflows/claude.yml`

Triggers on `@claude` mention in:
- Issue body / new issue
- PR review comment
- PR review submission
- Issue comment

Uses `anthropics/claude-code-action@beta` with `ANTHROPIC_API_KEY` secret. Runs in GitHub-hosted Linux. Has access to the PR's code + standard Claude Code tools. Timeout 60 min.

**Use when:** you want to ask Claude to do something specific on a PR ("@claude please refactor this to use the existing helper" / "@claude review the SQL safety").

**Limitations:** can't run dev server, can't access local machine, can't post to external services (no MCP).

---

## 2. Daily batch — `documenters-pr-review-agent`

**Source:** `aidd-personal-dc/ai-agents/documenters-pr-review-agent/`
**Installed:**
- Script: `~/bin/daily-documenters-pr-review.sh`
- launchd: `~/Library/LaunchAgents/com.duongcao.daily-documenters-pr-review.plist`
- Schedule: **daily 08:30 local** (between scrapers PR review at 08:00 and conflict resolver at 09:00)

**Flow:**
1. `gh pr list` on `City-Bureau/documenters` — open, current year, no bots, no drafts.
2. For each PR not yet approved by `duongcao-ea`: parallel `claude -p` with `/code-review` skill, max 4 concurrent.
3. Output: one markdown file per PR at `~/pr-reviews/documenters_PR<N>.md` (overwritten daily).
4. Logs at `~/pr-reviews/_logs/run-documenters-<YYYY-MM-DD>.log`.

**Auth:** GitHub PAT pulled from macOS Keychain service `daily-pr-review-gh-pat`. Same PAT as the scrapers agent.

**Bug fixed during setup:** background workers were inheriting the parent's stdin (the `WORK_FILE` FD), causing the read loop to hit EOF early. Fix is `run_one … </dev/null &`. The scrapers-pr-review-agent has the same bug — fix not yet applied there.

**Reload after edits:**
```bash
launchctl bootout gui/$(id -u)/com.duongcao.daily-documenters-pr-review
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.duongcao.daily-documenters-pr-review.plist
```

**Manual run:** `~/bin/daily-documenters-pr-review.sh`

**Git:** committed to `aidd-personal-dc@main` at `8b77a7b`.

---

## 3. On-demand interactive — `/pr-review` slash command

**File:** `~/.claude/commands/pr-review.md` (global, user-scope)

**Trigger:** `/pr-review <PR-url>` or `/pr-review <owner/repo#N>` in any Claude Code session.

**Workflow (codified in the prompt body):**
1. Parse the argument → owner/repo/number.
2. Fetch PR context — prefer GitHub MCP, fall back to `gh` CLI.
3. Detect Linear `[A-Z]{2,5}-\d+` refs in PR body, fetch via Linear MCP if connected.
4. Choose review depth by LOC (quick / standard / deep).
5. Launch up to 3 parallel **Explore** subagents (usage scope, pattern consistency, test gap).
6. Verify every cited `file:line` directly before quoting in the review.
7. Conditional skill chaining:
   - `security-review` if diff matches auth/SQL/secret patterns.
   - `simplify` if 20 < LOC < 500.
8. Compose structured markdown: BLOCKER / NIT / OBSERVATION + suggested regression test + pre-merge checklist.
9. Write to `./PR<N>_REVIEW.md` in cwd.

**Use when:** you want a single, deep, source-verified review with parallel agent exploration and skill chaining. Heavier than the daily agent — best for important PRs.

---

## 4. On-demand agentic — `documenters-issue-to-pr-agent`

**Source:** `aidd-personal-dc/ai-agents/documenters-issue-to-pr-agent/` (not yet pushed to remote)

**Five independent agents, each a fresh `claude -p` process with its own context:**

| Agent | Model | Input | Output | Tools |
|---|---|---|---|---|
| `analyzer` | Sonnet 4.6 | `issue.md` | `requirements.json` | Read, Glob, Grep, WebFetch, Bash |
| `planner` | Sonnet 4.6 | `requirements.json` | `tasks.json` | Read, Glob, Grep |
| `implementer` | **Opus 4.7** | one task + workdir | git commits in workdir | Read, Edit, Write, Bash, Glob, Grep |
| `validator` | Sonnet 4.6 | workdir + tasks | `validation.json` | Read, Bash, Glob, Grep |
| `pr-opener` | Sonnet 4.6 | full state + branch | `pr.json` (PR url) | Read, Bash |

**Communication:** filesystem JSON files in `flows/<flow-id>/`. No shared context — that's the design.

**Safety stop:** `flow.sh run` defaults to stop at `validate`. Human reviews local commits + validation report before explicitly invoking `flow.sh pr <flow-id>` to push + open PR. Override with `--auto-pr` flag (at your own risk).

**Quick usage:**
```bash
# 1. Save Linear issue body to markdown (include "DOC-NNNN" anywhere)
cat > /tmp/doc-1234.md <<EOF
DOC-1234: Title
...
EOF

# 2. Run through validate (stops before PR)
./bin/flow.sh run /tmp/doc-1234.md

# 3. Review locally
cd flows/<flow-id>/workdir
git log --oneline origin/development..HEAD

# 4. If happy, open PR
cd -
./bin/flow.sh pr <flow-id>
```

**Resume from any step:** `flow.sh resume <flow-id>`. State persisted in `flows/<id>/state.json`.

**Use when:** you have a well-scoped Linear issue and want Claude to draft the implementation end-to-end. Not for ambiguous tickets — the planner needs concrete acceptance criteria.

---

## 5. Global config — `~/.claude/`

### `~/.claude/settings.json`
- `permissions.allow`: 29 entries covering `gh pr/issue/api/run/auth/repo` + `mcp__github__*` + `mcp__linear__*` read-only tools. Eliminates permission prompts for review reads.
- `defaultMode: auto`.
- `code-review@claude-plugins-official` plugin enabled.

### `~/.claude.json` — MCP servers (user scope)

| Server | Status | Notes |
|---|---|---|
| `github` | ✓ connected | `npx @modelcontextprotocol/server-github`, auth via `GITHUB_PERSONAL_ACCESS_TOKEN` (from `gh auth token`) |
| `linear` | ✗ failing | OAuth token `lin_api_...` expired. Re-auth via `mcp__linear__authenticate` flow. |
| `claude.ai Google Calendar/Gmail/Drive` | needs auth | Unused for documenters workflow |

### `~/.claude/skills/` (global)
- `code-review` — bundled skill, Scrapy-flavored examples but core review mindset is general
- `setup-staging-workflow` — for city-scrapers repos

### `~/.claude/commands/` (global)
- `pr-review.md` — the slash command described in §3

---

## 6. Artifacts

| Path | Source | Lifetime |
|---|---|---|
| `~/pr-reviews/documenters_PR<N>.md` | daily agent + slash command | overwritten daily |
| `~/pr-reviews/_logs/run-documenters-<DATE>.log` | daily agent orchestrator | one per day |
| `~/pr-reviews/_logs/documenters_PR<N>.log` | daily agent worker stderr | overwritten per PR per day |
| `~/pr-reviews/_logs/launchd-documenters-{stdout,stderr}.log` | launchd | appended |
| `./PR<N>_REVIEW.md` (cwd) | `/pr-review` slash command | per invocation, in cwd |
| `aidd-personal-dc/ai-agents/documenters-issue-to-pr-agent/flows/<id>/` | issue→PR flow | per flow, gitignored |

---

## Layer comparison — which one to use when

| Situation | Best layer | Why |
|---|---|---|
| Quick check on every open PR daily | **Daily batch** | Free pass, no human action needed |
| Deep verified review on one PR before merge | **`/pr-review` slash command** | Parallel agents + source verification + structured output |
| Reviewer asked Claude to do something specific on a PR | **Reactive `@claude`** | Already wired, lives in GitHub thread |
| Well-scoped Linear ticket → draft implementation | **Issue→PR agentic flow** | End-to-end automation with human checkpoint at validate |
| Ad-hoc question / debugging session | Plain Claude Code session | No automation needed |

---

## Known gaps / follow-ups

1. **Linear MCP** is disconnected. Re-auth needed for the `/pr-review` command and the issue→PR flow to read DOC-NNNN ticket context automatically. Workaround for now: paste issue body into the prompt.
2. **`scrapers-pr-review-agent`** has the same stdin-inheritance bug as the documenters agent — one-line fix (`</dev/null &`) not yet applied there.
3. **Issue→PR flow** not yet tested end-to-end with a real DOC ticket. Test on a small, well-defined bug fix first to calibrate planner/implementer behavior.
4. **Issue→PR flow** not yet pushed to `aidd-personal-dc` remote.
5. **No CI integration** for the daily-generated reviews. Currently they sit in `~/pr-reviews/`; could surface them in a Slack channel or as PR comments (with care — many bots is noisy).

---

## Quick reference — most common commands

```bash
# Daily PR review — manual trigger
~/bin/daily-documenters-pr-review.sh

# Single PR deep review (in any Claude session)
/pr-review https://github.com/City-Bureau/documenters/pull/1234

# Start an issue→PR flow
cd ~/duong.cao/aidd-personal-dc/ai-agents/documenters-issue-to-pr-agent
./bin/flow.sh new /tmp/doc-NNNN.md
./bin/flow.sh run <flow-id>          # stops at validate
./bin/flow.sh pr <flow-id>           # human-gated push + PR

# Re-auth Linear MCP (in a Claude session)
# 1. Trigger:    use mcp__linear__authenticate
# 2. Open the returned URL in browser, authorize
# 3. Complete:   use mcp__linear__complete_authentication with the callback URL

# Reload daily agent after editing the script or plist
launchctl bootout gui/$(id -u)/com.duongcao.daily-documenters-pr-review
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.duongcao.daily-documenters-pr-review.plist
```
