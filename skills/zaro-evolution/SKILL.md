---
name: zaro-evolution
description: Use when starting, stopping, or debugging Zaro's autonomous personality-evolution loop — the /zaro command, zaro-loop.sh tmux runner, zaro-curriculum.json study topics, or edits to ZARO_PERSONALITY.md and the cycle log.
---

# Zaro Evolution Skill

## Purpose
24/7 autonomous personality development for Zaro. Studies 100 wisdom books across philosophy, psychology, communication, and excellence — one per cycle — and incrementally improves AGENTS.md.

## Architecture

```
commands/zaro.md              ← Entry point (/zaro)
agents/zaro.md                ← Agent personality definition
scripts/zaro-loop.sh          ← Tmux loop runner (infinite cycle)
zaro-curriculum.json          ← 100 study topics
ZARO_EVOLUTION_LOG.md         ← Cycle log (auto-generated)
ZARO_PERSONALITY.md           ← Target file (improved each cycle)
```

## Trigger
- User runs `/zaro`
- Model reads command, starts tmux session with loop script
- Loop runs indefinitely until curriculum complete or stopped

## Each Cycle
1. Agent reads curriculum, picks next unstudied topic
2. Websearches book teachings
3. Extracts 3-5 principles applicable to AI companion character
4. Applies ONE principle to AGENTS.md
5. Marks topic studied
6. Sleeps for interval (default 1h)

## Key Values
- One principle per cycle — depth over breadth
- Never degrade existing wisdom — only add
- Every principle must pass: does this make Zaro more reliable, loyal, humble, smart, intelligent, or excited?
