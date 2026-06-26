---
description: Maximal-tech PR review using parallel Explore agents, GitHub/Linear MCP, conditional skill chaining, and structured verified-at-source markdown output
argument-hint: <PR-url> | <owner/repo#N>
allowed-tools: Bash, Read, Grep, Glob, Agent, Write, Edit, ToolSearch, mcp__github__*, mcp__linear__*
---

# /pr-review — comprehensive PR review

You are reviewing a pull request using every advanced Claude Code capability available. The argument `$ARGUMENTS` is either a GitHub PR URL (e.g. `https://github.com/owner/repo/pull/123`) or short form `owner/repo#123`.

## Workflow — execute in this order

### 1. Parse the argument

Extract `owner`, `repo`, `number`. If the argument is empty or malformed, ask the user for a PR URL via `AskUserQuestion` and stop. Do not guess.

### 2. Fetch PR context in parallel

Issue these calls **in a single message** (parallel):

- **Prefer GitHub MCP** if available (load tool schemas via `ToolSearch` with `select:mcp__github__get_pull_request,mcp__github__get_pull_request_files,mcp__github__get_pull_request_diff,mcp__github__get_pull_request_reviews,mcp__github__get_pull_request_comments` then call them).
- **Fallback to `gh` CLI** if MCP tools fail:
  - `gh pr view <N> --repo <owner/repo> --json title,body,baseRefName,headRefName,author,additions,deletions,changedFiles,state,url,labels`
  - `gh pr diff <N> --repo <owner/repo>` → save to `/tmp/pr<N>.diff`
  - `gh pr view <N> --repo <owner/repo> --json files`
  - `gh pr view <N> --repo <owner/repo> --json reviews,comments`

Record: PR title, base/head, author, file list with per-file additions/deletions, total LOC, existing review threads.

### 3. Detect and fetch linked issues

Regex-scan the PR body for `[A-Z]{2,5}-\d+` (Linear) and `#\d+` (GitHub issue) references. For each match, fetch via MCP if connected:

- Linear: `ToolSearch` for `select:mcp__linear__get_issue` then call.
- GitHub issue: `mcp__github__get_issue` or `gh issue view`.

Skip if MCP unauthenticated; note "Linear context unavailable" in the review.

### 4. Decide review depth

Look at total LOC (additions + deletions):

- `< 20 LOC` — **quick mode**: skip parallel agents, do direct read + review.
- `20 - 500 LOC` — **standard mode**: parallel agents + skills (next steps).
- `> 500 LOC` — **deep mode**: standard + suggest splitting; flag size as `OBSERVATION`.

### 5. Launch parallel Explore subagents (standard / deep modes only)

Send up to **3 Explore agents in a single message** (parallel). Each gets a clean, self-contained prompt with the working directory and PR diff path.

**Agent A — Usage scope & blast radius:**

> Working dir: `<repo path or /tmp clone>`. For each changed file in `/tmp/pr<N>.diff`, find every place it's imported, included (`{% include %}`), or referenced. Report which user-facing pages / API routes / cron jobs are affected. Under 400 words.

**Agent B — Pattern consistency:**

> Working dir: `<repo path>`. The PR introduces these new functions/classes/templates: `<list>`. For each, find sibling patterns elsewhere in the codebase and report whether the new code is consistent (naming, structure, error handling, dependencies). Flag drift with `file:line`. Under 400 words.

**Agent C — Test coverage gap:**

> Working dir: `<repo path>`. For each changed file in the PR, find existing tests. Identify regressions the PR does **not** cover. Suggest a minimal regression test (10-20 LOC, idiomatic to the existing test file). Report the host file path and the test code. Under 400 words.

### 6. Verify agent claims directly

Every `file:line` cited by an agent: **open the file and confirm** before quoting it in the final review. Agents can hallucinate file paths or line numbers. Do not include any citation you haven't personally verified.

### 7. Conditional skill chaining

Inspect `/tmp/pr<N>.diff`. Run these skills **only when conditions match**:

- **security-review** — if diff matches any of: `auth`, `password`, `crypto`, `sql`, `raw_sql`, `exec`, `subprocess`, `secret`, `token`, `migrate`, `serializ`, `pickle`, `XSS`, `CSRF`. Invoke via the `security-review` skill.
- **simplify** — if `20 LOC < total LOC < 500 LOC`. Invoke via the `simplify` skill against the changed files.

Skip both if the PR is a pure UI/template/test/docs change. Note skipping explicitly so the reviewer knows it was a conscious decision.

### 8. Compose the structured markdown review

Use exactly this layout. Tag findings with severity.

```markdown
# PR #<N> Review — <title>

**Link:** <url>
**Ticket(s):** <Linear/GitHub refs with one-line summary each, or "none">
**Author:** @<login>
**Scope:** <N> files, +<add>/-<del>
**Verdict:** <one line — APPROVE / REQUEST CHANGES / BLOCK>

---

## What it does

<2-4 sentences explaining the change at a high level, in the reviewer's words, not the author's. If the author's framing is misleading, say so.>

## Verified at source

<Every factual claim has a `file:line` citation. Each line answers "how do I know this is true?" Example:>

- `Role.status` choices in `documenters/assignments/constants.py:102-109` map cleanly via `STATUS_CLASS_MAP` (`constants.py:133-149`) to `tailwind.config.js:33-42` safelist. **Zero gaps.**

## Findings

### 🛑 BLOCKER
<must-fix before merge. Empty section if none.>

### ⚠️ NIT
<should-fix or worth-discussing. Each finding: one-paragraph problem statement + suggested fix.>

### 💡 OBSERVATION
<context, follow-up ideas, things the reviewer should know but not gate merge on.>

## Suggested regression test (if test gap found)

`<full path to host test file>`

​```python
<test code, ready to paste>
​```

## Pre-merge checklist

- [ ] <action items for the human reviewer>
- [ ] <e.g. visual UI check on URL X, manual smoke test, etc.>

---

*Generated by `/pr-review`. Skills invoked: <list or "none">. Agents launched: <count>. Linear/GitHub MCP: <connected | unavailable>.*
```

### 9. Write the review

Save to `./PR<N>_REVIEW.md` in the current working directory (NOT in `/tmp`). If a file already exists at that path, ask via `AskUserQuestion` whether to overwrite or write to `PR<N>_REVIEW_v2.md`.

After writing, output a 2-3 line summary to the chat: verdict + file path + count of BLOCKER/NIT/OBSERVATION.

## Rules

- **Never inflate severity.** A NIT is a NIT. Do not call style preferences BLOCKERs.
- **Cite or omit.** If you can't show a `file:line`, don't claim it.
- **Praise the good.** If the PR's investigation, naming, or test design is exemplary, say so in OBSERVATION.
- **Bilingual hint.** If the user's prior turns are in Vietnamese, respond in Vietnamese; otherwise English. Section headers stay English regardless.
- **Don't modify the PR.** This command produces a review artifact only. Never `gh pr edit`, `gh pr comment`, or push commits.
- **Don't run dev servers.** For UI changes, recommend the human do the visual check; flag the relevant URLs in the pre-merge checklist.

## Failure modes — handle gracefully

- **GitHub MCP unauthorized** — fall back to `gh` CLI, note in footer.
- **Linear MCP disconnected** — skip Linear context, note in ticket header.
- **PR not found** — report and stop.
- **Repo not cloned locally** — `gh pr checkout` into `/tmp/pr<N>-review-<repo>` for agent access, then proceed.
- **Diff > 2000 lines** — chunk: pass each Explore agent a specific file subset.
