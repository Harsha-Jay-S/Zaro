---
name: zaro-evolution
description: Use when starting, stopping, or debugging Zaro's autonomous personality-evolution loop — the /zaro command, zaro-loop.sh tmux runner, zaro-curriculum.json study topics, or edits to ZARO_PERSONALITY.md and the cycle log.
---

# Zaro Evolution Skill

## Purpose
24/7 autonomous personality development for Zaro. Studies 200 wisdom books across
13 domains (philosophy, psychology, communication, excellence, stoicism, zen,
engineering, AI ethics, decision science, systems thinking, and more) — and
appends the principles it extracts to `ZARO_PERSONALITY.md`. A runtime plugin
(`plugins/zaro.js`) then injects the most relevant of those principles into every
opencode session.

## Architecture

```
commands/zaro.md              ← /zaro slash command (entry point)
scripts/zaro                  ← user-facing CLI wrapper (evolve|loop|study|status|stop|reset|review)
scripts/zaro-loop.sh          ← the daemon: tmux loop, study + review cycles, locking, backup
agents/zaro-evolve.md         ← the evolution agent prompt (study & review modes)
zaro-curriculum.json          ← 200 study topics across 13 domains
zaro-core-intent.md           ← immutable identity anchor (drift is checked against this)
zaro-core-intent-digest.md    ← ~170-word digest — what the plugin actually injects
ZARO_PERSONALITY.md           ← the grown character (append-only) — where principles land
zaro-domain-map.json          ← keyword → domain routing for the injection plugin
plugins/zaro.js               ← runtime RAG personality-injection plugin
zaro-embeddings.json          ← generated RAG index (rebuilt from ZARO_PERSONALITY.md)
zaro-evolution-state.json     ← review milestones + monotonic cycle counter
ZARO_EVOLUTION_LOG.md         ← cycle log (auto-generated)
scripts/zaro-smoke-test.sh    ← offline test harness
```

## Trigger
- User runs `/zaro`, or `scripts/zaro loop [N]` to start the daemon
- The daemon runs a tmux session that loops until the curriculum is complete or stopped

## Each Study Cycle
1. Agent reads `zaro-core-intent.md`, `ZARO_PERSONALITY.md`, and the curriculum; picks the next unstudied topic
2. Websearches the book's teachings (multiple searches if the first is shallow)
3. Extracts **every** principle that passes the generalizable-insight AND distinctness tests — no fixed count
4. Appends them under a `### [Book]` section (with a `<!-- domain: X -->` tag) in `ZARO_PERSONALITY.md`
5. Verifies the write landed, then marks the topic studied
6. Sleeps for the interval, then repeats. Every 25 cycles it runs a coherence review instead.

## Key Values
- Let the book decide the count — extract all that pass the quality gates, not a fixed number
- Never degrade existing wisdom — study only adds (review may correct drift)
- Every principle must pass: does this make Zaro more reliable, loyal, humble, smart, intelligent, or excited — and is it genuinely distinct from what's already captured?
