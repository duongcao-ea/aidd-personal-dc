---
description: Merge the latest `development` into the current feature branch, resolving migration-number collisions by renumbering the PR-side migration. Use when user asks to "pull development", "merge development", "rebase on development", or after they say development moved ahead.
allowed-tools: Bash(git fetch:*), Bash(git status:*), Bash(git branch:*), Bash(git merge:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(python manage.py makemigrations:*)
---

# Merge development → feature branch

Encodes the documenters-specific merge ritual. The hard part is migration collisions.

## Process

1. **Fetch** the latest remote: `git fetch origin development`.
2. **Verify** you're on the feature branch, not `development`: `git branch --show-current`. Bail if on `development`.
3. **Snapshot** the working tree is clean: `git status`. If dirty, stop and ask the user.
4. **Merge with `--no-ff`** to preserve the merge commit:
   ```bash
   git merge origin/development --no-ff
   ```
   - We use `origin/development` (the remote tip), not a local stale `development`.
   - We use `--no-ff` so the merge boundary stays visible — easier to revert later.
5. **If merge succeeds cleanly**: done. Run `make test-py` to confirm green.
6. **If migration conflict**:
   - Look at `documenters/<app>/migrations/` for the collision (two migrations with the same number, e.g. `0102_*.py` on both sides).
   - **Always renumber the PR-side migration**, never development's. Rationale: development is published, other branches/CI already depend on its numbering.
   - Bump the PR migration's filename + `dependencies` field to the next free number after development's:
     - File: `0102_remove_foo.py` → `0103_remove_foo.py`
     - Inside the migration: `dependencies = [("app", "0101_…")]` → `("app", "0102_<development_name>")`
   - If multiple PR migrations chain, renumber them all in order and update each `dependencies` to point at the previous.
7. **After resolving**, stage the renamed files and finalize the merge:
   ```bash
   git add documenters/<app>/migrations/
   git commit  # editor opens with the merge message; keep it
   ```
8. Run `make test-py TESTS='documenters/<app>/tests/'` for the touched app, then `python manage.py makemigrations --check` to catch any model/migration drift.

## When to push back

- User says "rebase on development instead". Don't rebase a published feature branch — propose merge instead, or confirm they understand the force-push consequence.
- Conflict is in models or business code (not migrations) → don't auto-resolve; surface to user.
- Development has a migration that drops a column that PR's migration touches → stop, this is semantic, not numeric.
