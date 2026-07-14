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

## Plugin load path (the trap)

The authoritative plugin registry is the opencode `plugin` array in
`~/.config/opencode/opencode.json` — **not** any project-dir config. To confirm
the plugin actually loads (registration ≠ loading), run any `opencode run` and
look for the boot line `[zaro] Ready (N sections)`. Editing the wrong config
layer is a silent no-op.

## Testing

`npm test` (or `bash scripts/zaro-smoke-test.sh`) — 11 offline assertions
(no tmux/daemon/network). Run it after any change to the daemon, plugin, or
domain map. It includes a sandboxed review that proves injection-safety (#2) and
scoped reaping (#3).

## Generated / runtime files (gitignored)

- `zaro-embeddings.json` — RAG index, rebuilt by the plugin when
  `ZARO_PERSONALITY.md` mtime changes. First build downloads the MiniLM model.
- `*.log` — `ZARO_EVOLUTION_RUNNER.log`, `zaro-injections.log`.

## Key commands

`scripts/zaro {evolve|loop [N]|study N|status|stop|reset|review}` — user-facing
wrapper. `zaro loop [seconds]` starts the daemon; `zaro status` shows progress.
