Zaro's 24/7 personality evolution engine. Studies 200 wisdom books via websearch and appends the principles it extracts (as many as each book genuinely offers) to ZARO_PERSONALITY.md.

## Arguments (each maps to a `zaro-loop.sh` subcommand)
- `once` — Run one study cycle now (`zaro-loop.sh once`)
- `daemon [N]` — Start the tmux daemon loop (`zaro-loop.sh start [N]`), N=seconds between cycles (default 3600 = 24 cycles/day)
- `stop` — Kill the tmux daemon (`zaro-loop.sh stop`)
- `status` — Show curriculum progress and daemon state (`zaro-loop.sh status`)
- `reset` — Restart curriculum, all topics unstudied (`zaro-loop.sh reset`)

## I execute the script like this:
```
~/.config/opencode/scripts/zaro-loop.sh <subcommand> [N]
```
(note: the `daemon` argument runs the `start` subcommand — they're the same thing.)

## How each mode works

### `once` mode
Runs `zaro-loop.sh once`, which executes a single study cycle in-process (an
`opencode run` with `agents/zaro-evolve.md` as the prompt — not a separate task
subagent). The agent:
1. Loads `brainstorming` for deep exploration; `caveman` for token efficiency
2. Reads core-intent, ZARO_PERSONALITY.md and curriculum, finds next topic
3. Websearches book teachings, extracts every principle passing the insight + distinctness gates (no fixed count)
4. Edits ZARO_PERSONALITY.md with principles, then verifies the write landed
5. Marks topic studied in curriculum
6. Logs to ZARO_EVOLUTION_LOG.md

### `daemon` mode (24/7 tmux)
I run `zaro-loop.sh start [N]` which creates a tmux session that loops:
```
pick next topic → opencode run --model opencode/deepseek-v4-flash-free --auto --print-logs "<Mode:study header> + agents/zaro-evolve.md" → sleep N → repeat
```
The agent prompt is the contents of `agents/zaro-evolve.md` passed inline (not a `--agent` flag). Each `opencode run` loads the plugins registered in opencode.json automatically, so the subagent has full skill access. Study/review cycles are serialized by a file lock, and the personality file auto-backs up to the ~/Zaro git mirror after each.

### `stop`
I run `zaro-loop.sh stop` which sends SIGINT then kills the tmux session.

### `status`
I run `zaro-loop.sh status` and show the output.

## Check what was learned
```
cat ~/.config/opencode/ZARO_EVOLUTION_LOG.md
```
