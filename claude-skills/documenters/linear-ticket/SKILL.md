---
description: Fetch a Linear ticket (DOC-XXXX) — pull title, body, AC, state, URL. Use when starting work on a ticket, before drafting a commit/PR, or when the user references "DOC-NNNN" without giving context. Falls back to git log if Linear MCP isn't connected.
allowed-tools: Bash(git log:*), Bash(claude mcp list:*)
argument-hint: [DOC-XXXX]
---

# Linear ticket context

Pull the canonical context for a documenters ticket so subsequent work (planning, commits, PRs) doesn't fly blind.

## Step 1 — detect ticket key

- If user passed `DOC-XXXX` explicitly, use it.
- Else: extract from current branch name via `git branch --show-current` (pattern `feature/doc-(\d+)-…`).
- Else: scan `git log --oneline -5` for the most recent `DOC-XXXX` reference.
- Else: ask the user — don't fabricate.

## Step 2 — fetch via Linear MCP (preferred)

Check if Linear MCP is connected:
```bash
claude mcp list | grep -E "^linear:.*✓"
```

If connected, call the Linear tool (the exact tool name depends on the MCP server's tool catalog — typical names: `mcp__linear__get_issue`, `mcp__linear__list_issues`). Pass `DOC-XXXX` as the identifier. Surface:

- **Title** (full, including any `[f]` prefix)
- **State** (In Progress / In Review / Done / …)
- **URL** (`https://linear.app/<workspace>/issue/DOC-XXXX/<slug>`) — needed for commit body
- **Body** (description + acceptance criteria) — needed for planning
- **Assignee, Cycle, Project** if present — context for prioritization

## Step 3 — fallback when Linear MCP is offline

If the MCP isn't reachable (status `✗ Failed to connect` or missing entirely):
1. Grep recent commits for the same ticket: `git log --all --grep='DOC-XXXX' --oneline -5`.
2. Read the body of the most recent matching commit (`git log -1 --format=%B <sha>`) — the Linear URL is in there per project convention.
3. Surface what you have; tell the user "Linear MCP not connected — only commit-history context available; reconnect with `/mcp` for full ticket body".

## Step 4 — report shape

Output to chat as a tight block — no boilerplate:

```
DOC-2399 · In Progress · https://linear.app/citybureau/issue/DOC-2399/...
Title:    Decouple stagger from limiter for env-tunable headroom
AC:       <bulleted criteria from body>
Notes:    <anything else load-bearing>
```

Then offer: "Plan a `PLAN_DOC-2399.md`?" / "Draft commit for current changes?" / "Open feature branch?" — let the user pick the next step.

## Anti-patterns

- Don't dump the full Linear body if it's long — summarize AC + paste URL.
- Don't fabricate the ticket URL slug from the title; either fetch via MCP or take it from a prior commit.
- Don't call the MCP when the user only wants the URL and a recent commit already has it.
