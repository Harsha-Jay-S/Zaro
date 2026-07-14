# Zaro Architecture

## Overview

Zaro is a self-evolving AI companion personality system for opencode. Two layers:

- **RUNTIME** — personality injection plugin (`plugins/zaro.js`) that retrieves relevant principles from ZARO_PERSONALITY.md and injects them into every session's instruction block
- **EVOLUTION** — daemon (`scripts/zaro-loop.sh`) that studies books, extracts principles, and grows the personality autonomously

## File Map

### Identity Layer (immutable foundation)

| File | Purpose |
|---|---|
| `zaro-core-intent.md` | Immutable identity — who Zaro is, 4 non-negotiables, how Zaro works and grows |
| `ZARO_PERSONALITY.md` | 96 sections × 1-5 bullet points each. Each section = one principle from a book, operationalized for Zaro's context |
| `AGENTS.md` | Global agent instructions — injected into every opencode session, references personality |

### Runtime Layer (per-session injection)

| File | Purpose |
|---|---|
| `plugins/zaro.js` | RAG-powered personality injection plugin. Three-tier fallback: RAG → pattern matching → recent sections |
| `zaro-embeddings.json` | Pre-computed 384-dim vectors for all 96 sections. Used by RAG tier |
| `zaro-domain-map.json` | 9 domains × 8 keywords each. Used by pattern-matching fallback |

### Evolution Layer (background growth)

| File | Purpose |
|---|---|
| `scripts/zaro-loop.sh` | Daemon: loops through unstudied curriculum topics, calls `opencode run` to study each |
| `scripts/zaro` | User-facing CLI wrapper. Commands: `evolve`, `loop`, `study N`, `status`, `stop`, `reset`, `review` |
| `scripts/build-embeddings.mjs` | One-time: parses ZARO_PERSONALITY.md, embeds sections via @xenova/transformers, writes zaro-embeddings.json |
| `zaro-curriculum.json` | 150 topics (ids 1-150). 100 studied, 50 unstudied (ids 101-150) |
| `zaro-curriculum-2.json` | 50 metacognition topics — operationalize personality principles into templates/behaviors |
| `zaro-evolution-state.json` | Tracks coherence review milestones and drift corrections |
| `agents/zaro-evolve.md` | Evolution agent prompt: how to study a topic, how to review for drift |

### Config Layer

| File | Purpose |
|---|---|
| `opencode.jsonc` | Registers plugin, custom commands (zaro-*), cavecrew agents, MCP, model config, instructions |
| `package.json` | Dependencies: @xenova/transformers, @opencode-ai/plugin |
| `plugins/zaro.js` | ES module plugin loaded by opencode on start |

## Data Flow

### Runtime (per message)

```
User message
  → plugins/zaro.js chat.message hook fires
    → Tier 1: RAG
      → embed user message via @xenova/transformers (local ONNX, ~50ms)
      → cosine similarity against 96 stored vectors
      → if top-1 score ≥ per-domain threshold → inject top-3 sections
    → Tier 2: Pattern matching (if RAG below threshold)
      → split message into words, check each against domain-map keywords
      → if domain match → inject all sections from that domain
    → Tier 3: Recent sections (if pattern matching fails)
      → inject 2 most recent sections from ZARO_PERSONALITY.md
  → Injected as <personality-context> block in instructions
  → Model generates response grounded in injected personality
```

### Evolution (per daemon cycle)

```
Daemon picks next unstudied topic from curriculum.json
  → calls opencode run with zaro-evolve.md agent instructions
  → Agent:
    1. Reads AGENTS.md, ZARO_PERSONALITY.md, curriculum topic
    2. Websearches the book's core teachings
    3. Extracts 3-5 principles applicable to Zaro
    4. Edits ZARO_PERSONALITY.md: adds new section with domain tag
    5. Marks topic as studied in curriculum.json
    6. Logs to ZARO_EVOLUTION_LOG.md
  → Every 25 cycles: coherence review
    → Compares new principles against zaro-core-intent.md
    → Corrects drift (delete/rewrite/merge)
    → Updates zaro-evolution-state.json
```

## Three-Tier Fallback Design

```
                    ┌─────────────┐
                    │ User message │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
          ┌─────────┤  <5 words?  ├─────────┐
          │         └──────┬──────┘         │
          │          no    │                │ yes
          ▼                ▼                ▼
    [SKIP RAG]     ┌──────────────┐    [Go straight
          │        │  RAG Tier    │     to Tier 2]
          │        │  (semantic)  │
          │        └──────┬───────┘
          │               │ score ≥ threshold?
          │          ┌────┴────┐
          │          │         │
          │        yes        no
          │          │         │
          │          ▼         ▼
          │    [Inject    ┌──────────────┐
          │     top-3]    │  Tier 2      │
          │               │  (pattern)   │
          │               └──────┬───────┘
          │                      │ domain match?
          │                 ┌────┴────┐
          │                 │         │
          │               yes        no
          │                 │         │
          │                 ▼         ▼
          │           [Inject    ┌──────────────┐
          │            domain    │  Tier 3      │
          │            sections] │  (recent)    │
          │                      └──────┬───────┘
          │                             │
          │                             ▼
          │                      [Inject 2 most
          │                       recent sections]
          └────────────────┬────────────────────┘
                           │
                           ▼
                   <personality-context>
                   [injected sections]
                   </personality-context>
                           │
                           ▼
                   Model generates response
```

## Domain Distribution

| Domain | Sections | Curriculum topics | Status |
|---|---|---|---|
| philosophy | 24 | 26 | Overweight |
| psychology | 23 | 23 | Good |
| communication | 18 | 18 | Good |
| excellence | 16 | 18 | Good |
| engineering | 7 | 12 | Thin |
| stoicism | 3 | 10 | Thin |
| zen | 2 | 8 | Thin |
| ai ethics | 2 | 8 | Thin |
| productivity | 1 | 10 | Thin |
| decision science | 0 | 5 | Missing |
| creativity | 0 | 4 | Missing |
| biography | 0 | 4 | Missing |
| systems thinking | 0 | 4 | Missing |

Philosophy + psychology = 47% of all sections. Engineering, stoicism, zen, ai ethics, productivity together = 15%. Four domains exist only in curriculum with zero personality sections.

## RAG Embedding Pipeline

```
ZARO_PERSONALITY.md
  → parseSections() splits into 96 sections
  → each section embedded via Xenova/all-MiniLM-L6-v2
    → embedding text = heading + first bullet point (summary)
    → output: 384-dim L2-normalized vector
  → stored in zaro-embeddings.json as {heading, body, domain, vector}

At query time:
  → user message embedded with same model
  → cosine similarity (equivalent to dot product since normalized)
  → top-3 by score
  → injection gate: top-1 score ≥ per-domain threshold
```

## Daemon Architecture

```
scripts/zaro-loop.sh (main entry)
  ├── start [N]  → tmux session, runs _run_loop with N-second interval
  ├── stop       → tmux kill-session
  ├── status     → shows progress + daemon state
  ├── once       → runs one study cycle
  ├── study N    → studies specific topic ID
  ├── reset      → clears all studied state
  └── review     → runs coherence review now

_run_loop:
  while get_next_topic != DONE:
    opencode run --model ... "Mode: study" + agent instructions
    sleep interval
    every 25 cycles: _run_coherence_review

_opencode run calls:
  zaro-evolve.md agent → websearch → extract principles
  → edit ZARO_PERSONALITY.md → mark curriculum.json studied
```

## Fallback Chain (Error Handling)

| Failure | Behavior | Mitigation |
|---|---|---|
| Embedding model fails to load | RAG disabled, pattern matching only | Logged (console.error) |
| RAG query fails (API error) | Falls to Tier 2 pattern matching | Logged |
| Personality file missing | Empty injection, no personality | No personality in session |
| Embeddings cache corrupted | Rebuild on boot | Silent (logged) |
| Domain map missing | Pattern matching fails gracefully | Falls to Tier 3 |
| Daemon study fails (retries exhausted) | Logged, topic NOT marked studied | Continues to next topic |
| Daemon crash | tmux session becomes dead | Handled by `zaro stop` or manual `tmux kill-session` |

## Key Metrics

- 96 personality sections across 9 domains
- 43,579 total words in personality, avg 453 words/section
- 150 curriculum topics (13 domains)
- 384-dim embedding vectors from all-MiniLM-L6-v2
- ~50ms embedding time per query (local ONNX)
- ~15ms boot time (cached embeddings)
- 8 custom commands in opencode.jsonc
- 6 custom agents registered
- 6 coherence reviews completed, 0 drift corrections

## Traceability

Every injection decision passes through three tiers with increasing generality:
1. RAG: precise semantic match → logged with scores
2. Pattern match: keyword overlap → logged with matched domain
3. Recent: no data-driven match → logged as fallback

The injection log (zaro-injections.log) records which tier fired, which sections were injected, and their scores — enabling post-hoc analysis of injection quality.
