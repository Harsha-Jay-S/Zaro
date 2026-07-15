# Zaro — v2 Recommendations (analysis only, NOT implemented)

Written per the plan's Phase 3. These are proposals to discuss — none are built.
The confirmed decision for this pass was: keep bash+tmux, keep runtime RAG.

## 1. Daemon form — keep bash, add a supervisor (don't rewrite)
Bash+tmux is now injection-safe and scope-safe (findings #2/#3). A full Node/Go
rewrite buys little and risks regressing hard-won lifecycle handling. If more
robustness is wanted, the cheapest win is a **systemd user service** wrapping the
existing script (`Restart=on-failure`, journald logging) instead of tmux — no
code rewrite, better crash recovery, real log rotation. Tradeoff: ties Zaro to
systemd; tmux is more portable and inspectable (`tmux attach`).

## 2. Delivery — keep runtime RAG; measure its precision
Registration is fixed and the plugin loads (118 sections, ~8ms). Before trusting
it, **measure retrieval quality**: extend `zaro-analyze.mjs` (or a new probe
script) to run ~20 representative prompts and eyeball whether injected sections
are actually relevant. If precision is poor, the lever is per-domain thresholds
in `zaro-domain-map.json` (already supported), not a rewrite. Baking personality
statically into AGENTS.md was considered and rejected: it loses per-query
relevance and grows every session's context.

## 3. Injection budget — enforce, don't assume — DONE (2026-07-15)
Was: <500 tokens target, but core intent alone (~400 words) already exceeded it
before any section was added — 1300-1450 tokens measured, confirmed via a real
A/B benchmark against 10 live model runs, which also found this caused an actual
regression (pushed a refactor-advice request into tool-mode). Fixed: a ~170-word
`zaro-core-intent-digest.md` replaces the full file at injection time (source
untouched), the "recent sections" no-match fallback (injected random content at
0% relevance) was removed, and `formatInjection`'s hard cap does section-aware
trimming — drops whole lowest-scored sections instead of slicing mid-sentence.
Verified: ~500-1000 tokens per injection now, zero noise on off-topic prompts.
See `.zaro-lessons/2026-07-15-injection-ab-fix-round.md`.

## 4. Curriculum-2 merge — one careful step
`zaro-curriculum-2.json` (50 metacognition topics) is ready but unwired. Merging
means appending its topics to `zaro-curriculum.json` with fresh ids and adding
any new domains to `zaro-domain-map.json` (the #6 pattern). The monotonic cycle
counter (#4 fix) already handles the larger topic set correctly. Do this only
when the current 25 remaining topics are done.

## 5. Study throughput
150 cycles × 1h interval ≈ 6+ days wall-clock. If faster growth is wanted, lower
the interval (the daemon already supports `zaro loop <seconds>`); parallelizing
study cycles is NOT recommended — it breaks the append-only, one-principle-per-
cycle coherence model and the review cadence.

## 6. Open — does `chat.message` fire during `opencode run`?
Attempted to verify this session (2026-07-15), inconclusive. Every `opencode run`
invocation (60s/90s/120s/150s, then a full 600s run) hung at the identical `init`
log line, before reaching message processing — traced to MCP tool-registration
(dozens of orphaned `mcp-server --server http://localhost:5000` processes from
repeated `context7-mcp` spawns), not a Zaro bug. Matters if the daemon's study
cycles are meant to receive personality injection during a study/review cycle —
right now `agents/zaro-evolve.md` has the study agent read `ZARO_PERSONALITY.md`
and `zaro-core-intent.md` directly as files (Phase 1 of both modes), so it isn't
currently *dependent* on injection firing, but whether it *also* gets injected
context is unconfirmed. Needs a cleaner environment (or a TUI session instead of
one-shot `run`) to test without the MCP hang in the way.

## 7. Open — RAG precision noise floor
The A/B benchmark's 12-prompt retrieval sweep: 7/12 relevant, 4/12 noise (fixed
this round — no-match now injects digest-only, not random sections), 1/12 false
positive (`"database haiku"` → 26% on a philosophy section via literal "table"
keyword collision in the embedding). That false positive was accepted as noise
floor rather than chased — threshold tuning can't cleanly separate it from real
hits in the same 23-31% score band. Worth revisiting once `zaro-curriculum-2.json`
(50 more topics) is merged (item 4) — more sections in the embedding index changes
the collision/precision math and may be worth re-measuring rather than assuming
the same accept-as-noise-floor call still holds.
