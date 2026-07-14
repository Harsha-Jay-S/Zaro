# Zaro — Actual Architecture (post-fix, 2026-07-15)

Companion to the intended-design doc at `~/Zaro/ZARO_ARCHITECTURE.md` (which is
stale: it says 96 sections / 100 studied and references a `build-embeddings.mjs`
that isn't present). This describes the system **as it actually runs** after the
10-finding fix pass, with the real data flow and the load path that was verified
end-to-end.

## Layers & real responsibilities

```
daemon (scripts/zaro-loop.sh, tmux)
  → per cycle: get_next_topic → run_opencode_scoped(study) → mark studied → incr counter
  → every REVIEW_INTERVAL completed cycles: run_opencode_scoped(review) → mark_review_done
     brain (agents/zaro-evolve.md + AGENTS.md)
       → study: research book → add principle to ZARO_PERSONALITY.md (+ <!-- domain: X -->)
       → review: audit recent additions vs zaro-core-intent.md, correct drift
          plugin (plugins/zaro.js)  ← LOADED via opencode.json "plugin" array (verified)
            → on chat.message: embed query → cosine vs zaro-embeddings.json (118 vecs)
            → Tier1 RAG (per-section threshold) → Tier2 keyword (zaro-domain-map.json)
            → Tier3 recent → always prepend zaro-core-intent.md → <personality-context>
               state/data
                 zaro-curriculum.json (150 topics, 125 studied) [curriculum-2.json = +50, NOT wired]
                 zaro-evolution-state.json (last_review_milestone, cycles_completed, reviews[])
                 zaro-embeddings.json (rebuilt by zaro.js when personality mtime changes)
                 zaro-injections.log (append per injection; analyzed by scripts/zaro-analyze.mjs)
```

## Verified load path (the #1 finding)

opencode boots → `message=loading path=~/.config/opencode/opencode.json` →
`[zaro] Initializing personality injection plugin` → `[zaro] Ready (118 sections)`.
There is **no** competing project config: `~/Zaro/` holds only a doc, and the
daemon log's `directory=~/Zaro` is merely the run cwd. Global
`~/.config/opencode/opencode.json` is the authoritative plugin registry.

## Notable actual-vs-intended gaps (not bugs, worth knowing)

- `scripts/zaro-analyze.mjs` is a **read-only log report tool**, not an embedder
  and not part of the loop; it is never invoked automatically.
- The RAG index is built **inside zaro.js** (`ensureEmbeddings`), keyed on
  `ZARO_PERSONALITY.md` mtime — not by a separate build script.
- `zaro-curriculum-2.json` (50 topics) exists but the daemon only reads
  `zaro-curriculum.json`; merging it is a deliberate future step.

## Failure modes (post-fix behavior)

| Component fails | Behavior now |
|---|---|
| Agent emits summary with quotes/`$(...)` | Stored verbatim via argv; daemon survives (was: crash under `set -e`). |
| opencode run hangs | `timeout $RUN_TIMEOUT` kills it; retry with backoff (≤5). |
| Orphan MCP children after a run | Reaped by process group of that one run only — never a host-wide sweep. |
| State write fails | Logged as non-fatal warning; daemon continues. |
| Embedding/model load fails | zaro.js falls back to keyword (Tier2) / recent (Tier3); never throws into the session. |
| RAG top section below threshold | No sub-threshold siblings injected; falls to Tier2/Tier3. |

## Verification artifact

`scripts/zaro-smoke-test.sh` — 11 offline assertions (file validity, plugin
registration, per-section gate, full domain coverage, and a sandboxed review
proving apostrophe-safety + scoped reaping). Run it after any change to this
system.
