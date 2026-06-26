---
description: Review a documenters PR using the project's lens (senior-architect "is there a simpler way?", dead code, dramatiq/migration gotchas) and write the full review to `PR<number>_REVIEW.md` at repo root. Use when user asks "review PR #1911", "look at this PR", "self-review my branch", or similar.
allowed-tools: Bash(gh pr view:*), Bash(gh pr diff:*), Bash(gh pr list:*), Bash(git diff:*), Bash(git log:*), Read, Grep, Glob
---

# Review a documenters PR

Encodes the project review convention: full review → file at repo root, short summary in chat.

## Process

1. **Fetch the PR context.**
   - If user gave a PR number (`#1911`): `gh pr view 1911 --json title,body,baseRefName,headRefName,files,additions,deletions,url` and `gh pr diff 1911`.
   - If reviewing the current branch (no PR yet): `git diff origin/development...HEAD` + `git log origin/development..HEAD`.
   - Read the Linear ticket if linked (URL in PR body) — context for "is this the right fix?".

2. **Apply the documenters review lens** in this order:

   **a. Correctness first** — does it do what the ticket asks? Edge cases? Error paths?

   **b. Is there a simpler way?** Review like a senior architect:
      - After verifying correctness, surface 1–3 simpler alternatives.
      - Question whether each piece of machinery is load-bearing. Could a config flag replace a new abstraction? Could a one-liner replace a class?
      - Don't just validate — push back on unnecessary structure.

   **c. Dead code & thin wrappers** — call out:
      - Unreachable methods (especially ones with tests that silently pass).
      - Single-call-site lazy-import wrappers.
      - Unused imports, vars, exceptions.

   **d. Documenters-specific gotchas** (from `CLAUDE.md` § Known gotchas):
      - New `@dramatiq.actor`? Has explicit `max_retries`? Has idempotency guard against duplicate sends (Basecamp/email)?
      - New migration? Reversible? RunPython has reverse op? Numbered correctly vs `development`?
      - Touches `meetings/builders.py` `_get_or_create_agency`? Race-condition aware?
      - Uses `programs.set()` on Agency? Should it be `.add()` to preserve manual assignments?
      - `import_meeting_json` silent drop on unknown `scraper_name`? At minimum log a metric/Sentry event.

   **e. Tests** — present, correct, would catch a real regression? Or a "test that always passes"?

   **f. Scope** — does the PR stay within ticket AC, or did it grow "while I'm at it" UA/observability/cleanup adds? Flag scope creep.

3. **Write the full review to `PR<number>_REVIEW.md`** at repo root.
   - If no PR number (reviewing current branch), use `REVIEW.md` or `PR_REVIEW_<branch>.md`.
   - Structure:
     ```markdown
     # PR #<N>: <title>

     **Branch:** <head> → <base>  ·  **Linear:** <URL>  ·  **Scope:** <one-line>

     ## Verdict
     <approve / request changes / discuss>

     ## Must fix
     - …

     ## Discuss / simpler alternatives
     - …

     ## Nits
     - …

     ## What's good
     - …
     ```
   - Use `file:line` for every code reference so the user can jump.

4. **Post a short summary in chat** — verdict + top 2-3 issues with file:line. Don't paste the whole review; the file has it.

## When to push back

- User asks for "a quick LGTM" → still run the lens. Quick reviews miss the gotchas.
- PR is huge (>500 lines) → recommend splitting first; review the first slice.
- PR has no Linear ticket linked → ask before reviewing — scope might be unclear.
