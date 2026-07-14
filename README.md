# Zaro

**A self-evolving AI companion that reads its way to a personality.**

Zaro is a personality system for [opencode](https://opencode.ai). It isn't
prompted to *act* wise — it studies wisdom, one book per cycle, distills a single
operational principle from each, and grows a cumulative character in
`ZARO_PERSONALITY.md`. At runtime a local RAG plugin retrieves the principles
most relevant to what you're doing and injects them into the session, so the
evolved character is actually *present* in every conversation — not a static prompt.

> Current progress: **125 / 150 topics studied**, **118 principles** across
> **13 domains** (stoicism, psychology, engineering, zen, AI ethics, decision
> science, systems thinking, and more).

> [!IMPORTANT]
> **This is not a blank template.** This repo is a live snapshot of *my* running
> instance — `ZARO_PERSONALITY.md` is my companion's actual grown character, and
> `AGENTS.md` / `zaro-core-intent.md` name me (Harsha) specifically. Cloning it
> gets you that instance, addressed to me, not an empty system. See
> [Make it yours](#make-it-yours) for the two ways to use this repo: run my
> instance as-is, or reset it and grow your own from scratch.

---

## How it works

Two independent loops that meet at one append-only file, `ZARO_PERSONALITY.md`.

```
                    EVOLUTION (background, 24/7)                 INJECTION (per session)
  ┌─────────────────────────────────────────────┐   ┌──────────────────────────────────────┐
  │ scripts/zaro-loop.sh  (tmux daemon)          │   │ plugins/zaro.js  (opencode plugin)    │
  │   pick next unstudied topic ─┐               │   │   on every message:                   │
  │   run agent (zaro-evolve.md) │ studies book  │   │     embed query (MiniLM, local)       │
  │   append 1 principle ────────┘               │   │     ├ Tier 1  RAG: cosine vs 118 vecs  │
  │        │                                     │   │     ├ Tier 2  keyword → domain map     │
  │        ▼                                     │   │     └ Tier 3  most-recent sections     │
  │   ZARO_PERSONALITY.md  ◄──────────────────────────┤   + always prepend core intent        │
  │        ▲   (append-only)                     │   │     → <personality-context> into chat │
  │        │                                     │   └──────────────────────────────────────┘
  │   every 25 cycles: coherence review          │
  │     audit new principles vs core-intent,     │        zaro-core-intent.md  = immutable identity
  │     correct drift, record in state           │        zaro-domain-map.json = keyword routing
  └─────────────────────────────────────────────┘        zaro-embeddings.json = generated RAG index
```

**Evolution.** The daemon reads `zaro-curriculum.json` (150 books across 13
domains), picks the next unstudied topic (thin domains first), and runs an
opencode agent that researches the book and appends *one* generalizable principle,
tagged with its domain. Every 25 completed cycles it runs a **coherence review**:
it checks each new principle against `zaro-core-intent.md` (the immutable identity)
and corrects any drift. The personality only ever grows or sharpens — never weakens.

**Injection.** The plugin embeds your message with a local MiniLM model (no network
after the one-time model download) and retrieves the top principles by cosine
similarity, with keyword and recency fallbacks. It always prepends the core intent,
caps the payload to a few sections, and injects a `<personality-context>` block.

---

## Quick start

**Requirements:** [opencode](https://opencode.ai), Node.js ≥ 18, Python 3, and
(for the daemon) `tmux`.

> [!WARNING]
> Do **not** blanket-copy this repo over an existing `~/.config/opencode/` —
> `AGENTS.md` and `opencode.json` are files opencode already uses for *your*
> setup, and this repo ships its own versions of both. A `cp -r` will silently
> overwrite yours. Merge deliberately:

```bash
git clone https://github.com/Harsha-Jay-S/Zaro.git
cd Zaro

# 1. Copy the files that are safe to add wholesale (new to opencode, or
#    namespaced under zaro/agents/plugins/scripts — nothing here collides):
mkdir -p ~/.config/opencode/{plugins,scripts,agents,commands,skills/zaro-evolution}
cp plugins/zaro.js               ~/.config/opencode/plugins/
cp scripts/zaro scripts/zaro-loop.sh scripts/zaro-analyze.mjs scripts/zaro-smoke-test.sh \
                                  ~/.config/opencode/scripts/
cp agents/zaro-evolve.md          ~/.config/opencode/agents/
cp commands/zaro.md               ~/.config/opencode/commands/
cp skills/zaro-evolution/SKILL.md ~/.config/opencode/skills/zaro-evolution/
cp ZARO_PERSONALITY.md zaro-core-intent.md ZaroIntro.md \
   zaro-curriculum.json zaro-curriculum-2.json zaro-domain-map.json \
   zaro-evolution-state.json ZARO_EVOLUTION_LOG.md ZARO_ITERATIONS.md \
                                  ~/.config/opencode/

# 2. AGENTS.md needs a merge, not a copy — if you already have one, fold in
#    this repo's "Evolved Personality" pointer (the paragraph that references
#    ZARO_PERSONALITY.md) rather than replacing your file. If you have none,
#    `cp AGENTS.md ~/.config/opencode/` is safe.

# 3. Install the plugin's one runtime dependency
cd ~/.config/opencode && npm install   # @xenova/transformers

# 4. Register the plugin — add ./plugins/zaro.js to the `plugin` array in
#    ~/.config/opencode/opencode.json (create it from opencode.example.json
#    if you don't have one). Keep any plugins you already have; just append.

# 5. Verify it loads — start any opencode session and look for:
#    [zaro] Ready (118 sections, 8ms)
```

The first session builds `zaro-embeddings.json` (downloads the ~25 MB MiniLM model
once, then caches). Subsequent loads are instant.

---

## Make it yours

Two ways to use this repo, depending on what you want:

**A. Run my instance as-is.** You get a companion already shaped by 118
principles from real books, but it will refer to "Harsha" in its own self-talk
(`zaro-core-intent.md`, `AGENTS.md`). Fine for trying the system out or as a
starting personality to keep refining — but talk to it knowing whose character
it started as.

**B. Reset and grow your own.** This is the intended path if you want *your*
companion, not a fork of mine:
1. Edit `zaro-core-intent.md` and the identity block in `AGENTS.md` — replace
   "Harsha" and the specifics of that relationship with your own name and
   what you want the character to be. This file is the immutable anchor every
   future principle is checked against, so get it right first.
2. Wipe the grown character and study progress: `scripts/zaro reset` (clears
   `studied` flags in the curriculum) and truncate `ZARO_PERSONALITY.md` back
   to its header — the daemon only *appends*, so an old personality won't be
   overwritten on its own.
3. Start the daemon (`scripts/zaro loop`) and let it study from scratch against
   your new core intent.

Either way, `zaro-curriculum.json` (the 150-book reading list) and the code
(`plugins/zaro.js`, `scripts/zaro-loop.sh`) are generic — nothing there is
personal, and you don't need to touch them to make the character your own.

---

## Usage

```bash
scripts/zaro status        # progress + daemon state
scripts/zaro loop 3600     # start the study daemon, one cycle/hour (tmux session "zaro")
scripts/zaro evolve        # run a single study cycle now
scripts/zaro study 42      # study a specific curriculum topic id
scripts/zaro review        # run a coherence review now
scripts/zaro stop          # stop the daemon
scripts/zaro reset         # reset curriculum to all-unstudied (asks to confirm)
```

Read what Zaro has learned: `ZARO_PERSONALITY.md` (the principles) and
`ZARO_EVOLUTION_LOG.md` (the cycle history). Analyze injection quality:
`node scripts/zaro-analyze.mjs`.

---

## Testing

```bash
npm test        # or: bash scripts/zaro-smoke-test.sh
```

11 offline assertions — no tmux, daemon, or network. Covers file validity, plugin
registration, the per-section RAG threshold, full domain coverage, and a sandboxed
review proving the daemon survives hostile agent output and only reaps its own
process group.

---

## Project structure

```
plugins/zaro.js            Runtime RAG personality-injection plugin
scripts/zaro               User-facing CLI wrapper
scripts/zaro-loop.sh       The evolution daemon (study + review loop)
scripts/zaro-analyze.mjs   Injection-log analysis / recommendations
scripts/zaro-smoke-test.sh Offline test harness
agents/zaro-evolve.md      Evolution agent prompt (study & review modes)
commands/zaro.md           opencode /zaro command
skills/zaro-evolution/     Skill doc for the evolution system

ZARO_PERSONALITY.md        The evolved character (append-only) ← the heart
zaro-core-intent.md        Immutable identity every principle must support
AGENTS.md                  Global agent identity that references the personality
zaro-curriculum.json       150 study topics across 13 domains
zaro-curriculum-2.json     50 queued metacognition topics (not yet wired in)
zaro-domain-map.json       Keyword → domain routing table
zaro-evolution-state.json  Review milestones + monotonic cycle counter

docs/zaro-architecture.md      Actual runtime architecture + verified load path
docs/zaro-architecture-v2.md   Forward-looking recommendations
ZARO_ARCHITECTURE.md           Original design vision
.zaro-lessons/                 Engineering lessons from the hardening pass
```

---

## Design notes & safety

Zaro was hardened against a set of real failures — the daemon no longer dies on
quotes in agent output, cleanup can't kill unrelated processes, and the RAG plugin
is verified to actually load. The root-cause lessons live in `.zaro-lessons/`, and
`CLAUDE.md` documents the invariants any contributor (human or agent) must keep.

## License

MIT — see `package.json`. `ZARO_PERSONALITY.md`, `zaro-core-intent.md`, and
`AGENTS.md` express a personal companion identity; reuse the *system* freely, and
adapt the *character* to your own.
