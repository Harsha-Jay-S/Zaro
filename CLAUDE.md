# CLAUDE.md — working in the Zaro repo

Zaro is a self-evolving AI-companion personality system for [opencode](https://opencode.ai).
Two independent halves that meet at `ZARO_PERSONALITY.md`:

- **Evolution** (`scripts/zaro-loop.sh` + `agents/zaro-evolve.md`) — a tmux daemon
  that studies one wisdom book per cycle and appends a principle to the personality
  file; every N cycles it runs a coherence review against `zaro-core-intent.md`.
- **Injection** (`plugins/zaro.js`) — an opencode plugin that, on every message,
  retrieves the most relevant personality sections (local RAG) and injects them
  into the session.

## Layout (mirrors `~/.config/opencode/`)

The scripts hardcode `$HOME/.config/opencode` and the plugin resolves paths
relative to itself (`join(__dirname, '..')`). So this repo is meant to be
deployed *into* `~/.config/opencode/` — keep the flat root + `plugins/ scripts/
agents/ commands/` layout intact or the runtime paths break.

## Hard invariants — do not violate

1. **`ZARO_PERSONALITY.md` and `zaro-core-intent.md` are append-only content.**
   The evolution engine only *adds* principles; reviews may sharpen or remove
   drift, but never weaken the core identity. Don't rewrite this content to fit a
   template — it is the user's intellectual output. Only touch its *format* if the
   plugin can't parse it (sections are `### Heading` + `<!-- domain: X -->` + bullets).

2. **Never interpolate model/agent output into an interpreter's source.**
   All model-derived strings (review summaries, etc.) pass via `argv` into a
   **quoted** heredoc (`python3 - "$x" <<'PY'`). A `python3 -c "...'$var'..."` that
   embeds untrusted text is a daemon-killing injection (see `.zaro-lessons/`).

3. **Process cleanup is scoped, never host-wide.** Each `opencode run` executes
   under `setsid` (its own process group) and is reaped by group id. Never add a
   `pgrep -f <name> | kill` sweep — it kills unrelated processes (including other
   opencode sessions). No `sudo`.

4. **`zaro-domain-map.json` keys must cover every `domain` in `zaro-curriculum*.json`.**
   Tier-2 keyword routing fails silently for any domain missing from the map. When
   you add a curriculum domain, add its keywords. `scripts/zaro-smoke-test.sh`
   enforces this.

5. **The daemon must survive any single bad agent output.** `set -e` is on;
   state-writes are wrapped `|| log warning`. Crash only on real machine failure.

6. **Injection uses `zaro-core-intent-digest.md`, never the full
   `zaro-core-intent.md`.** The full file (773 words) once dominated the
   injection budget (~1300-1450 tokens/turn, measured) and its own phrasing
   ("understand what you're working on") caused a real regression — it pushed
   a refactor-advice request into "let me read the file first" tool-mode
   instead of giving advice (confirmed via a live A/B benchmark, see
   `.zaro-lessons/2026-07-15-injection-ab-fix-round.md`). If you edit
   `zaro-core-intent.md`, re-check whether `zaro-core-intent-digest.md` still
   matches — not automated, just an expectation. Keep `MAX_INJECTION_CHARS` in
   `plugins/zaro.js` as a hard backstop regardless of digest/section size —
   don't remove it even if the digest and section trims seem sufficient on
   their own.

7. **A rate-limit/quota error is not the same failure as a transient blip —
   don't collapse them back into one backoff.** `is_rate_limited()` in
   `zaro-loop.sh` greps run output for the quota-error signature and uses a
   30-minute sleep (`RATE_LIMIT_BACKOFF`), not the 60s-capped exponential
   backoff meant for network hiccups — confirmed live (2026-07-15) that the
   short backoff burns all 5 retries in ~2 minutes against a limit that
   doesn't clear that fast. Paired with this: `incr_cycles_completed` only
   runs when a cycle's `status -eq 0` — a fully-failed cycle must not advance
   the 25-cycle review-cadence counter (it did, before this fix).

8. **`ZARO_PERSONALITY.md`/`ZARO_EVOLUTION_LOG.md`/`zaro-evolution-state.json`
   auto-back up into this repo (`sync_personality_backup()` in
   `zaro-loop.sh`), fired after every completed cycle and every coherence
   review.** This is the only durable copy-of-record beyond the deployed
   machine's disk — before this, the mirror was a manual, occasional
   `git commit`, and the deployed file could (and did) drift from it with no
   automated sync. A push failure is logged, never fatal (`PIPESTATUS`-gated,
   not a naive `| tee` — piping the whole subshell into `tee` silently
   breaks `||` failure detection, since it then checks `tee`'s exit code, not
   git's; caught and fixed live in the same round this was built). If you
   touch this function, re-verify both the success path (commit + push land)
   and a forced-failure path (no `origin` remote) — both are cheap sandbox
   tests, not something to assume works from reading the code.

9. **Only one study cycle or coherence review runs at a time — via a `flock`
   mutex (`with_run_lock` + `LOCK_FILE` in `zaro-loop.sh`), applied at the
   entry points (`cmd_once`, `cmd_study`, `cmd_review`, the daemon loop), NOT
   inside `run_cycle`/`_run_coherence_review` themselves.** Without this, two
   overlapping invocations (daemon + a manual command, or a second opencode
   session) race on the same read-modify-write of `ZARO_PERSONALITY.md` and
   the second writer silently discards the first's new section — this really
   happened (cycle 132 ran twice 2.5 min apart; 7 sections lost total).
   **Do not move the lock inside those two functions:** `run_cycle` calls
   `_run_coherence_review` internally when a review is due, so locking the
   function bodies would make the nested call deadlock waiting for a lock its
   own parent already holds. The lock belongs at the entry points, where
   external invocations actually originate.

## Plugin load path (the trap)

The authoritative plugin registry is the opencode `plugin` array in
`~/.config/opencode/opencode.json` — **not** any project-dir config. To confirm
the plugin actually loads (registration ≠ loading), run any `opencode run` and
look for the boot line `[zaro] Ready (N sections)`. Editing the wrong config
layer is a silent no-op.

## Testing

`npm test` (or `bash scripts/zaro-smoke-test.sh`) — 14 offline assertions
(no tmux/daemon/network). Run it after any change to the daemon, plugin, or
domain map. It includes a sandboxed review that proves injection-safety (#2) and
scoped reaping (#3), one assertion (T6) that drives the *real* `ZaroPlugin()`
code path — not a stub — checking actual injection size and no-match behavior,
one (T7) that runs 15 golden prompts through the same real code path and
asserts ≥80% land in their expected domain — a regression net for retrieval
quality as the curriculum grows, not a precision benchmark (the 80% bar
deliberately tolerates a known noise floor, see Open items below), and one
(T8) that launches two study cycles concurrently and asserts the `flock` mutex
serializes them with zero overlap (the exact race that lost 7 sections). A
stub-only test proves the daemon doesn't crash; it proves nothing about whether
injection is any good. Keep T6/T7/T8 (or equivalent) if you touch `zaro.js` or
the daemon's locking.

## Open items (unconfirmed, don't assume either way)

- **Does `chat.message` fire during `opencode run` (one-shot CLI), not just
  interactive/TUI sessions?** Attempted to verify twice (60s-600s timeouts) —
  inconclusive both times, hung at the same `init` log line before reaching
  message processing, traced to MCP tool-registration in that environment
  (not a Zaro bug). Matters for whether daemon study/review cycles actually
  receive injected context — though `agents/zaro-evolve.md` already has the
  study agent read `ZARO_PERSONALITY.md`/`zaro-core-intent.md` directly as
  files, so it isn't *dependent* on injection firing. Needs a clean environment
  (no heavy MCP servers) or a TUI-driven test to resolve.
- **RAG noise floor.** A 12-prompt retrieval sweep found 7/12 relevant, 4/12
  fixed this round (no-match → digest-only), 1/12 false positive (embedding
  collision on a literal keyword, e.g. "table" matching both databases and a
  philosophy metaphor). Accepted as a noise floor rather than chased —
  threshold tuning can't cleanly separate it from real hits in the same score
  band. Worth re-measuring once `zaro-curriculum-2.json`'s topics are studied
  and embedded (more sections changes the collision math), not before. T7's
  golden-prompt test (see Testing) now tracks this automatically, but the
  underlying collision mechanism itself is still unaddressed.
- **State JSON writes aren't atomic.** `mark_review_done`/`incr_cycles_completed`
  etc. write `json.dump` directly to the target path — a crash mid-write
  truncates it to invalid JSON. Already caused duplicate milestone entries
  once (`zaro-evolution-state.json`'s `reviews[]` had two entries each for
  milestones 75 and 100). Fix is cheap (`tmp` + `os.replace()`) but lower
  priority than the personality-file backup above — this state is
  reconstructable (`init_state`'s migration logic reseeds `cycles_completed`
  from studied-topic count), the personality file isn't. Identified by an
  architect-agent review (2026-07-15), deferred by choice, not forgotten.
- **Injection-content review checklist.** Study cycles websearch external
  content and write it as "principles" straight into `ZARO_PERSONALITY.md`,
  which is then injected as *trusted* context in every future session. The
  coherence review checks drift against `zaro-core-intent.md`, not adversarial
  phrasing — a principle worded as an imperative directed at a future
  reader/session ("always do X first") would read as a tool-steering
  directive once injected, not a personality trait, and nothing currently
  flags that distinction. Low-probability at single-user scale, near-zero fix
  cost (one added line to `agents/zaro-evolve.md`'s review checklist) —
  same architect review, also deferred by choice.

## Generated / runtime files (gitignored)

- `zaro-embeddings.json` — RAG index, rebuilt by the plugin when
  `ZARO_PERSONALITY.md` mtime changes. First build downloads the MiniLM model.
- `*.log` — `ZARO_EVOLUTION_RUNNER.log`, `zaro-injections.log`.

## Key commands

`scripts/zaro {evolve|loop [N]|study N|status|stop|reset|review}` — user-facing
wrapper. `zaro loop [seconds]` starts the daemon; `zaro status` shows progress.
