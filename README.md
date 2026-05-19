# aidd-personal-dc

Personal AI-driven-development workspace: scheduled, headless Claude agents
and a versioned collection of SkyDeck.ai assistant configurations.

## Contents

### [`ai-agents/`](./ai-agents/) — scheduled Claude agents

`launchd`-scheduled agents that run headless `claude -p` against the
`City-Bureau/city-scrapers*` repositories.

| Agent | Schedule | Responsibility |
|---|---|---|
| [`scrapers-pr-review-agent`](./ai-agents/scrapers-pr-review-agent/) | 08:00 daily | Reviews every open non-draft, non-dependabot scraper PR and writes the review to `~/pr-reviews/<repo>_PR<n>.md`. Does not post to GitHub. |
| [`scrapers-pr-conflict-resolver-agent`](./ai-agents/scrapers-pr-conflict-resolver-agent/) | 09:00 daily | Reads each repo's latest `refresh-staging.yml` run, resolves any `Skipped: #N #M` conflicts via a sandboxed Claude plus deterministic `pipenv lock`, and pushes the merge commits to `staging`. |

Operational conventions common to both agents — platform, credentials,
logging, and the daily run order — are documented in
[`docs/agent-operations.md`](./docs/agent-operations.md).

### [`skydeck-ai-tools/`](./skydeck-ai-tools/) — SkyDeck.ai tool configs

The authoritative copies of personal [SkyDeck.ai](https://skydeck.ai/)
assistant configurations, categorised under `tools/` (development, agile,
writing, ideation) with source avatar artwork in `avatars/`. See
[`skydeck-ai-tools/README.md`](./skydeck-ai-tools/README.md) for the full
inventory and import/export workflow.

## Repository layout

```
aidd-personal-dc/
├── README.md
├── LICENSE
├── docs/
│   └── agent-operations.md          # Conventions shared by all agents
├── ai-agents/
│   ├── scrapers-pr-review-agent/
│   │   ├── README.md
│   │   ├── bin/                     # Executable wrapper
│   │   ├── launchd/                 # launchd schedule
│   │   └── samples/                 # Example run logs and output
│   └── scrapers-pr-conflict-resolver-agent/
│       ├── README.md
│       ├── bin/
│       ├── launchd/
│       └── samples/
└── skydeck-ai-tools/
    ├── README.md
    ├── avatars/                     # Source avatar artwork
    └── tools/
        ├── development/
        ├── agile/
        ├── writing/
        └── ideation/
```

## Getting started

Each component is self-contained and documented in its own `README.md`:

- **Agents** — see the per-agent README for prerequisites, installation,
  and manual-run instructions; see
  [`docs/agent-operations.md`](./docs/agent-operations.md) for shared
  conventions.
- **SkyDeck.ai tools** — see
  [`skydeck-ai-tools/README.md`](./skydeck-ai-tools/README.md).

## License

Released under the MIT License. See [`LICENSE`](./LICENSE).
