# Claude Code slash commands

Custom slash commands (the `~/.claude/commands/*.md` kind), invoked with
`/<name> <args>` from the chat input. Global — they work in every project.

Drop a file into `~/.claude/commands/` (global) or `.claude/commands/` (project)
to register it.

## Commands

| Command | What it does |
|---|---|
| [`pr-review`](./pr-review.md) | Maximal-tech PR review: fans out parallel `Explore` agents, pulls context via the GitHub/Linear MCP, conditionally chains the `security-review` / `simplify` skills, and writes a structured, verified-at-source review to `PR<N>_REVIEW.md` in the cwd. Argument is a PR URL or `owner/repo#N`. |
