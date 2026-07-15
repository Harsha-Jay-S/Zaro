# Lesson: an A/B benchmark found real problems a bug-fix pass couldn't

## One-line
"Verified correct" (loads, doesn't crash, passes unit-level assertions) and
"verified effective" (actually helps, doesn't actively hurt) are different
claims — only real model output comparison catches the second kind.

## What happened
The prior hardening pass (10 bugs, smoke-tested) shipped a working plugin.
Direct testing of the production code path then found it was *technically*
working but *practically* noisy: 1300-1450 tokens injected every turn, with
off-topic prompts getting content indistinguishable from on-topic ones. A
follow-up A/B benchmark (opencode itself, 10 live model runs comparing
with/without injection) went one step further and found the injection had
caused a real behavioral regression in one case — pushed a refactor-advice
request into "let me read the file first" tool-mode instead of giving advice.

## Root causes, fixed
1. **Full core-intent.md (773 words) injected verbatim every turn** — dominated
   the budget and, more importantly, contained legitimate engineering-discipline
   language ("I read before I edit") that read as a tool-invocation directive
   out of context. Fix: a separate ~170-word digest, hand-drafted to keep the
   identity but explicitly counter the tool-mode trigger ("when advice is
   needed, I give it, not a request to go read something first"). The full
   file stays untouched as the canonical source — CLAUDE.md's append-only rule
   never had to bend.
2. **Tier 3 injected 2 random sections at literal 0% relevance on any
   unmatched query** — "hi" and a pasta recipe question got the identical
   irrelevant book excerpts. Fix: removed the "recent sections" fallback
   entirely; a miss now injects the digest alone, no random section.
3. **Two real embedding misses** (burnout, "rewriting the same function 3x")
   scored 0% on RAG and had no keyword backstop either. Fix: added targeted
   domain-map keywords. One of the two ended up fixed by RAG alone on
   re-test (a slightly different phrasing scored above threshold) — the
   keyword backstop matters for phrasings that don't.

## What surprised me
- A claim I initially accepted at face value ("no cap on section length")
  was **factually wrong** — a 400-char cap already existed. But the person
  raising it was right about the *consequence* (budget still exceeded) even
  though wrong about the *mechanism*. Worth separating "is this claim literally
  true" from "does the underlying concern have merit" — both checks matter,
  and conflating them means either dismissing a valid concern over a wording
  error, or accepting a wrong claim because the worry behind it was real.
- A stub-based smoke test (fake `opencode` binary) proved the daemon survives
  hostile input, but told us nothing about injection quality — that needed a
  test calling the *actual* plugin code (`ZaroPlugin()` + the real
  `chat.message` hook), not a mock. Added that as a permanent smoke-test
  assertion (T6) now that the fix exists, so budget/noise can't silently
  regress again.
- Attempting to verify a live-model claim (does `chat.message` fire during
  `opencode run`) ran into a genuine environmental hang — MCP tool
  registration (repeated `context7-mcp` spawns via `npm exec`) never
  completing within any tested timeout, up to 600s. A shorter timeout doesn't
  help when the failure point is fixed regardless of duration — recognizing
  "this is a hang, not slowness" (via near-zero CPU growth over minutes) saved
  chasing a longer and longer timeout that would never resolve it.
