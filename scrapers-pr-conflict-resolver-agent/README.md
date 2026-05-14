# scrapers-pr-conflict-resolver-agent

Daily AI conflict-resolver agent for `City-Bureau/city-scrapers*` repos whose
`refresh-staging.yml` workflow skipped PRs due to merge conflicts against
`staging`.

## What it does

Daily at 9 AM local (after `refresh-staging` at 3 AM and [`scrapers-pr-review-agent`](../scrapers-pr-review-agent)
at 8 AM) `launchd` fires [`daily-conflict-resolver.sh --apply`](./daily-conflict-resolver.sh),
which:

1. Scans every active `City-Bureau/city-scrapers*` repo for a
   `refresh-staging.yml` workflow.
2. For each such repo, reads the latest workflow run's `Skipped: #N #M` line
   — those are the PRs `refresh-staging` itself reported as conflicting.
3. For each skipped PR:
   - Clones a fresh copy under `/tmp/pr-conflict-resolver/<repo>_PR<num>/`.
   - Trial-merges `pr-<num>` into `staging`.
   - **Code conflicts** → invokes sandboxed `claude -p` (Read/Edit/Glob/Grep
     plus read-only Bash). Prompt prefers the PR side on overlapping changes
     and asks the agent to drop `# TODO(human): verify auto-resolved merge`
     comments where it was uncertain.
   - **`Pipfile.lock` conflict** → bypasses the AI and runs `pipenv lock`
     against the merged `Pipfile`. Deterministic tool for a deterministic
     problem.
   - **External-contributor `Pipfile` change** (authorAssociation not in
     `{OWNER, MEMBER, COLLABORATOR}`) → refuses to auto-lock; that PR is
     bumped to manual review.
4. Pushes the merge commit directly to `origin staging` (fast-forward-only
   guard; refuses if `origin/staging` advanced since the clone).
5. Runs serially in `--apply` mode (`MAX_PARALLEL=1`) so concurrent pushes
   to the same `staging` branch can't race.

Commits land under your global git identity (no `github-actions[bot]`, no
co-author trailer).

## Files

| File | Purpose |
|---|---|
| `daily-conflict-resolver.sh` | Orchestrator. Install at `~/bin/daily-conflict-resolver.sh`. |
| `com.duongcao.daily-conflict-resolver.plist` | launchd schedule (09:00 daily, `--apply`). Install at `~/Library/LaunchAgents/`. |
| `samples/run-2026-05-14.log` | First production run on `city-scrapers-atl`: resolved 2 conflicting PRs (#205, #207). |

## Prerequisites

- `claude` CLI authenticated.
- `gh` CLI authenticated as `duongcao-ea`.
- `pipenv` available via `pyenv` (script auto-picks the highest pyenv
  interpreter that has `pipenv` installed and matches `Pipfile`'s
  `python_version`).
- macOS Keychain entry `daily-pr-review-gh-pat` containing a GitHub PAT with
  push permission (`Contents: write` + `Pull requests: write`, or classic
  `repo`). Reuses the same entry as `pr-review-agent`.
- macOS — paths in the plist are hard-coded for `/Users/duongcaochanh/`.

## Install

```bash
cp daily-conflict-resolver.sh ~/bin/daily-conflict-resolver.sh
chmod +x ~/bin/daily-conflict-resolver.sh
cp com.duongcao.daily-conflict-resolver.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.duongcao.daily-conflict-resolver.plist
```

## Manual run

```bash
# Dry-run (default): resolve locally, log intended changes, no push.
bash ~/bin/daily-conflict-resolver.sh
bash ~/bin/daily-conflict-resolver.sh --repo city-scrapers-atl

# Apply: push merge commits directly to staging (serialized).
bash ~/bin/daily-conflict-resolver.sh --apply
bash ~/bin/daily-conflict-resolver.sh --repo city-scrapers-atl --apply
```

Logs land in `~/pr-conflict-resolutions/_logs/run-<date>.log` (orchestrator)
and `~/pr-conflict-resolutions/_logs/<repo>_PR<num>.log` (per-task Claude
transcripts + git output).

## Safety properties

- **Never pushes to `staging` if our merge isn't a fast-forward of
  `origin/staging`.** Race condition → skip + retry next run.
- **Idempotent.** A second run after a successful one no longer finds the PR
  in refresh-staging's `Skipped:` list (because the conflict is gone), so
  nothing re-pushes.
- **No conflict markers ever get committed.** Sanity-check after AI resolution.
- **External-contributor `Pipfile` changes → human review.** Bounds the
  trust escalation when running `pipenv lock` against PRs from the public
  internet.
- **Recovery.** If a resolution turns out to be wrong, `git revert
  <merge-sha>` on `staging` and re-trigger `refresh-staging.yml`.

## Architectural choices

- **Why parse `refresh-staging`'s `Skipped:` line instead of trial-merging
  every PR?** refresh-staging already did the merge attempt and filtered out
  drafts/bots. Re-doing that work is wasteful and reaches different
  conclusions when timing differs (e.g., GitHub's async `mergeable` field
  reflects PR-vs-base, not PR-vs-staging).
- **Why `pipenv lock` instead of having the AI edit `Pipfile.lock`?**
  Lockfiles are *derived* artifacts. The mechanically-correct resolution is
  to rerun the generating tool against the merged manifest, not to merge
  content by hand. Earlier attempts at letting the AI edit lockfiles
  discarded one side's transitive deps silently.
- **Why push to `staging` directly instead of opening a follow-up PR?**
  Same trust posture as `refresh-staging.yml` (which also auto-pushes
  staging unattended). A follow-up PR adds a click that nobody clicks.
- **Why serialize pushes (`MAX_PARALLEL=1`) in apply mode?** Parallel
  workers on the same `staging` branch produce non-fast-forward pushes
  that get rejected. Serial is simpler than fetch-rebase-retry loops.
