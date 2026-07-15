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

## Plugin load path (the trap)

The authoritative plugin registry is the opencode `plugin` array in
`~/.config/opencode/opencode.json` — **not** any project-dir config. To confirm
the plugin actually loads (registration ≠ loading), run any `opencode run` and
look for the boot line `[zaro] Ready (N sections)`. Editing the wrong config
layer is a silent no-op.

## Testing

`npm test` (or `bash scripts/zaro-smoke-test.sh`) — 12 offline assertions
(no tmux/daemon/network). Run it after any change to the daemon, plugin, or
domain map. It includes a sandboxed review that proves injection-safety (#2) and
scoped reaping (#3), and one assertion (T6) that drives the *real* `ZaroPlugin()`
code path — not a stub — checking actual injection size and no-match behavior.
A stub-only test proves the daemon doesn't crash; it proves nothing about
whether injection is any good. Keep T6 (or equivalent) if you touch `zaro.js`.

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
  and embedded (more sections changes the collision math), not before.

## Generated / runtime files (gitignored)

- `zaro-embeddings.json` — RAG index, rebuilt by the plugin when
  `ZARO_PERSONALITY.md` mtime changes. First build downloads the MiniLM model.
- `*.log` — `ZARO_EVOLUTION_RUNNER.log`, `zaro-injections.log`.

## Key commands

`scripts/zaro {evolve|loop [N]|study N|status|stop|reset|review}` — user-facing
wrapper. `zaro loop [seconds]` starts the daemon; `zaro status` shows progress.
