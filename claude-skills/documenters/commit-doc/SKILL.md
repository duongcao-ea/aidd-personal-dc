---
description: Stage and commit changes in the documenters repo following the `[f] DOC-XXXX:` convention. Use when the user asks to commit, "create a commit", or finalize work on a DOC-XXXX ticket.
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*)
disable-model-invocation: false
---

# Commit on documenters

Encodes the project's commit ritual so the user never has to correct the format.

## Format (non-negotiable)

- **Subject**: `[f] DOC-XXXX: <imperative title>` — `<imperative title>` is short (~60 chars), starts with a verb (Add, Fix, Refactor, Decouple, Stagger, …). The `[f]` prefix marks feature/fix work; this is the project's convention, don't drop it.
- **Body**:
  - One short paragraph on the WHY (not the what — the diff shows the what).
  - Blank line.
  - Linear URL: `https://linear.app/<workspace>/issue/DOC-XXXX/...` — required.
- **No** `Co-Authored-By: Claude …` trailer. Documenters commits don't carry it.
- **No** `🤖 Generated with Claude Code` line.

## Process

1. Run `git status` and `git diff` (staged + unstaged) in parallel. Read the recent `git log --oneline -10` to mirror the existing tone.
2. **Split logically** — one concern per commit. If the diff mixes a bug fix + a refactor + a test cleanup, propose splitting. Don't just bundle.
3. **Ask for the Linear URL if missing.** Don't guess the ticket key from the branch name and fabricate a URL — confirm with the user. Branch names like `feature/doc-2399-...` are a hint, not a source of truth.
4. **Don't `git add -A`.** Stage files by name. Skip `.env*`, `*.log`, `*_REVIEW.md`, anything under `__pycache__/`.
5. Use a HEREDOC so the body formats correctly:

```bash
git commit -m "$(cat <<'EOF'
[f] DOC-2399: Decouple stagger from limiter for env-tunable headroom

Stagger and rate-limit headroom were coupled, so tuning one moved the
other. Split them so ops can dial the limiter independently per env.

https://linear.app/citybureau/issue/DOC-2399/...
EOF
)"
```

6. Run `git status` after the commit. If a pre-commit hook fails, **fix the underlying issue and create a NEW commit** — never `--amend` and never `--no-verify`.

## When to push back

- User says "just commit everything" but the diff spans unrelated concerns → propose a split first.
- User asks to commit migrations alongside unrelated code → confirm; migrations should usually be their own commit.
- Working tree has unrelated `PR<n>_REVIEW.md` files at root → don't stage them.
