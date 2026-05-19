# SkyDeck.ai Tool Configurations

Versioned source-of-truth for a personal collection of
[SkyDeck.ai](https://skydeck.ai/) assistant configurations used in
AI-driven development.

Each `*.json` file is a complete, importable SkyDeck.ai tool definition
(system prompt, model parameters, and an embedded base64 avatar). The files
in this directory are the authoritative copies; the SkyDeck.ai workspace is
treated as a deployment target, not the source of truth.

## Layout

```
skydeck-ai-tools/
├── README.md
├── avatars/                 # Source avatar artwork (also embedded in each JSON)
└── tools/
    ├── development/         # Coding, review, testing, migration assistants
    ├── agile/               # Story authoring and AIDD facilitation
    ├── writing/             # Documentation and communication assistants
    └── ideation/            # Brainstorming and concept clarification
```

## Tool inventory

### `tools/development/`

| File | Purpose |
|---|---|
| `api-documentation-tool.json` | Generates and refines API reference documentation. |
| `code-analysis-tool.json` | Analyses source for structure, smells, and risk. |
| `code-optimizer.json` | Suggests performance and clarity improvements. |
| `code-quality-checker.json` | Reviews code against quality and style standards. |
| `codemigrate-pro.json` | Assists with cross-language / cross-framework migration. |
| `debugging-assistant.json` | Walks through reproduction, isolation, and fixes. |
| `technology-advisor.json` | Recommends tools and stacks for a given problem. |
| `unit-test-generator.json` | Produces unit tests for supplied code. |

### `tools/agile/`

| File | Purpose |
|---|---|
| `agile-story-master.json` | Drafts and decomposes user stories and epics. |
| `aidd_partner.json` | AI-driven-development pairing facilitator. |
| `user-story-builder.json` | Builds well-formed user stories with acceptance criteria. |

### `tools/writing/`

| File | Purpose |
|---|---|
| `communication-pro.json` | Polishes professional and stakeholder communication. |
| `content-creation-tool.json` | Drafts long-form and structured content. |
| `text-summarizer.json` | Condenses documents into focused summaries. |

### `tools/ideation/`

| File | Purpose |
|---|---|
| `brainstorming-tool.json` | Facilitates structured idea generation. |
| `concept-clarifier.json` | Explains and disambiguates unfamiliar concepts. |

## Usage

Import a configuration into SkyDeck.ai:

1. Open the target SkyDeck.ai workspace.
2. Create or edit a tool and import the corresponding `tools/<category>/<name>.json`.
3. The embedded avatar is applied automatically; the matching source image
   in `avatars/` is kept for reference and re-export.

When a tool is changed in SkyDeck.ai, export it and commit the updated JSON
back to this directory so the repository stays authoritative.

## Conventions

- One tool per file; the filename matches the tool's purpose.
- Avatars are embedded (base64) in each JSON and additionally stored as
  source artwork under `avatars/`.
- Categories under `tools/` are organisational only and carry no meaning
  inside SkyDeck.ai itself.

## License

Released under the MIT License. See [`../LICENSE`](../LICENSE).
