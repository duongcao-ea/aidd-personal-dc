# aidd-personal-dc

Personal AI-driven-development projects — local cron AI agents, SkyDeck.ai
tool configs.

## Contents

### [`ai-agents/`](./ai-agents/) — daily Claude-powered agents

| Agent | Schedule | What it does |
|---|---|---|
| [`scrapers-pr-review-agent`](./ai-agents/scrapers-pr-review-agent/) | 08:00 daily | Auto-reviews every open non-draft, non-dependabot scraper PR. Writes markdown to `~/pr-reviews/<repo>_PR<n>.md`. No GitHub posting. |
| [`scrapers-pr-conflict-resolver-agent`](./ai-agents/scrapers-pr-conflict-resolver-agent/) | 09:00 daily | Reads each repo's latest `refresh-staging.yml` run, resolves any `Skipped: #N #M` conflicts via sandboxed Claude + deterministic `pipenv lock`, pushes the merge commits directly to `staging`. |

Both run as `launchd` jobs on macOS; both call headless `claude -p`.

Run order is intentional: refresh-staging at 03:00 generates the conflict
signal, review-agent at 08:00 produces reviews of every open PR, conflict-
resolver at 09:00 closes the loop by getting the conflict-blocked PRs back
into staging.

### [`skydeck-ai-tools/`](./skydeck-ai-tools/) — SkyDeck.ai tool configs

JSON configurations for [SkyDeck.ai](https://skydeck.ai/) personal
assistants, plus their avatar images. Each `*.json` file is one configured
tool (code analysis, debugging assistant, agile story master, etc.).

## Layout

```
aidd-personal-dc/
├── README.md
├── ai-agents/
│   ├── scrapers-pr-review-agent/
│   │   ├── daily-pr-review.sh
│   │   ├── com.duongcao.daily-pr-review.plist
│   │   ├── README.md
│   │   └── samples/
│   └── scrapers-pr-conflict-resolver-agent/
│       ├── daily-conflict-resolver.sh
│       ├── com.duongcao.daily-conflict-resolver.plist
│       ├── README.md
│       └── samples/
└── skydeck-ai-tools/
    ├── README.md
    ├── avatars/
    └── *.json
```

## Shared conventions for the agents

- **macOS-only** — `launchd` plist paths are hard-coded to
  `/Users/duongcaochanh/`.
- **GitHub PAT in Keychain.** Both agents read `daily-pr-review-gh-pat` via
  `security find-generic-password`. Needs push perms (`Contents: write` +
  `Pull requests: write`, or classic `repo`).
- **Logs live under `~/<output-dir>/_logs/`** — `~/pr-reviews/_logs/` for
  the review agent, `~/pr-conflict-resolutions/_logs/` for the resolver.

See each agent's `README.md` for install + manual-run instructions.
