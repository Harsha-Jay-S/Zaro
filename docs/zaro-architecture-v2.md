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

## 3. Injection budget — enforce, don't assume
Target is <500 tokens. Current `formatInjection` caps at 3 sections + core intent
+ `trimBody(400 chars)`. Core intent alone is ~400 words (~500 tokens), so the
budget is likely already exceeded before any section is added. Recommend:
inject a **condensed** core-intent (a 3-4 line digest) rather than the full file,
and add a hard character cap on the whole `<personality-context>` block. This is
a real, in-scope follow-up if context pressure disables the plugin.

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
