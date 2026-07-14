Zaro's 24/7 personality evolution engine. Studies 100 wisdom books via websearch and improves ZARO_PERSONALITY.md — one principle per cycle.

## Arguments
- `once` — Run one cycle now via task subagent (in-session)
- `daemon [N]` — Start tmux session `zaro` running the loop, N=seconds between cycles (default 3600 = 24 cycles/day)
- `stop` — Kill the tmux daemon
- `status` — Show curriculum progress and daemon state
- `reset` — Restart curriculum (all topics unstudied)

## I execute the script like this:
```
~/.config/opencode/scripts/zaro-loop.sh <arg> [N]
```

## How each mode works

### `once` mode (in-session)
I spawn a `general` subagent via the task tool. The agent:
1. Loads `brainstorming` skill for deep exploration of the topic
2. Uses `caveman` skill for token efficiency
3. Reads AGENTS.md and curriculum, finds next topic
4. Websearches book teachings, extracts 3-5 principles
5. Edits ZARO_PERSONALITY.md with principles
6. Marks topic studied in curriculum
7. Logs to ZARO_EVOLUTION_LOG.md

### `daemon` mode (24/7 tmux)
I run `zaro-loop.sh start [N]` which creates a tmux session that loops:
```
pick next topic → opencode run --agent zaro --model opencode/deepseek-v4-flash-free --auto → sleep N → repeat
```
Each `opencode run` loads the superpowers plugin automatically (from opencode.json config), so the subagent has full skill access.

### `stop`
I run `zaro-loop.sh stop` which sends SIGINT then kills the tmux session.

### `status`
I run `zaro-loop.sh status` and show the output.

## Check what was learned
```
cat ~/.config/opencode/ZARO_EVOLUTION_LOG.md
```
