---
description: Research a question before answering — parallel codebase exploration + official-docs lookup + write findings to `RESEARCH_<topic>.md` at repo root, then answer with file:line citations. Use when the user asks "how does X work?", "why does Y happen?", "what's the best way to do Z in this codebase?", "should we use A or B?", or any open-ended technical question that benefits from verified-at-source evidence rather than a guess from memory.
allowed-tools: Agent, Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(gh issue view:*), Bash(gh pr view:*), Read, Grep, Glob, WebFetch, WebSearch
---

# Research before answering

Encodes the project rule: **don't guess from memory — verify at source.** Matches the `INVESTIGATE_*.md` pattern already in use across the repo (see all the `INVESTIGATE_*.md` files at root).

## When to invoke

User asks an **open-ended question** where the answer isn't obvious from a quick file read:

- "How does the scraper dedup Agency rows?"
- "Why is `update_document_content` retrying so much?"
- "What's the right way to add a new dramatiq actor with idempotency?"
- "Should we use `select_related` or `prefetch_related` here?"
- "Where does Basecamp sync get triggered from?"
- "What changed in DocumentCloud rate-limiting last quarter?"

**Skip** for trivial lookups ("what's at `models.py:50`?") — just `Read` it.

## Process

1. **Classify the question.** Pick the slices that apply (often more than one):

   | Slice                 | Tool                          | Used when                                                  |
   | --------------------- | ----------------------------- | ---------------------------------------------------------- |
   | **Code locality**     | `Agent(subagent_type=Explore)`| Question is about how something works in this repo         |
   | **External API/lib**  | `WebFetch` on official docs   | Question involves Django/Dramatiq/OpenAI/Azure/Basecamp API |
   | **Recent change**     | `git log -p` / `gh pr view`   | Question is about *why* a piece of code looks this way      |
   | **Data shape**        | `agency-debug` skill / Postgres MCP | Question is about live DB state                       |
   | **Production behavior** | `heroku-log-auditor` agent  | Question is about what's actually failing in prod          |

2. **Spawn parallel agents in ONE tool message.** Per the project's `feedback_parallel_agents.md` memory entry — independent slices run concurrently, not sequentially.

   - Each agent gets a **self-contained prompt** explaining the *question*, not the search command (per global Agent guidance: "Investigations: hand over the question — prescribed steps become dead weight when the premise is wrong").
   - Cap reports — ask each agent for **under 200 words** + `file:line` citations.

   Example for "how does the scraper dedup Agency rows?":

   ```
   parallel:
   - Explore(very thorough): "Trace every code path that creates an Agency row. Focus on builders.py, utils.py, signals.py, any management command. Return file:line citations for each create call and the uniqueness check around it."
   - WebFetch(https://docs.djangoproject.com/en/5.0/ref/models/querysets/#get-or-create): "Confirm the exact atomicity guarantees of get_or_create vs three filter() calls + create()."
   - Bash: git log -p --follow documenters/meetings/builders.py | head -200
   ```

3. **Synthesize into `RESEARCH_<topic>.md` at repo root.** Topic = short snake_case slug (e.g. `RESEARCH_agency_dedup.md`, `RESEARCH_dramatiq_idempotency.md`). Mirrors the existing `INVESTIGATE_*.md` pattern so the `SessionStart` hook picks it up next session.

   **Structure:**

   ```markdown
   # Research: <one-line question>

   **Asked:** <YYYY-MM-DD>  ·  **Verdict:** <one-sentence answer>

   ## TL;DR
   <2-3 sentences. The answer + the load-bearing reason.>

   ## Evidence
   - `file:line` — what's there, why it matters
   - `file:line` — …
   - External: <doc URL> — what it confirms

   ## Trade-offs / open questions
   - …

   ## What I did NOT verify
   - <be explicit about gaps so future-you doesn't trust this further than it goes>
   ```

   **Every claim cites `file:line` or a URL.** No `file:line` → don't claim it (project rule: "no false alarms").

4. **Answer the user in chat — short.** 3-5 sentences. Verdict + the 1-2 most load-bearing citations. Point them at the file for depth: *"Full notes in `RESEARCH_<topic>.md`."*

## When to push back

- **User asks a question that's already answered in an existing `INVESTIGATE_*.md` / `RESEARCH_*.md` file** → read the existing file first; either confirm it's still accurate (cheap) or research the delta (don't redo from scratch).
- **User asks a yes/no question with an obvious answer** → just answer. Skill is for open-ended.
- **User asks for a recommendation** ("should we use X?") → research first, then recommend in 2-3 sentences per the project's "exploratory question" rule. Present as redirectable, not a decided plan.

## Anti-patterns

- ❌ Spawning agents sequentially when they're independent (wastes wall-clock).
- ❌ Writing the answer without `file:line` citations (becomes a memory entry that rots).
- ❌ Skipping the markdown file for "quick" questions — the project's `feedback_plan_to_markdown.md` memory says **markdown first**. If the question doesn't deserve a file, you shouldn't be invoking this skill.
- ❌ Citing what the memory says — re-verify at source. Memory can be stale.
