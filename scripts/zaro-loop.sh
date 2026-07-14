#!/bin/bash
# Zaro Evolution Daemon — runs in tmux, loops through curriculum
# Usage: zaro-loop.sh start|stop|status|once|reset|review [interval_seconds]

set -e

CONFIG_DIR="$HOME/.config/opencode"
CURRICULUM="$CONFIG_DIR/zaro-curriculum.json"
STATE_FILE="$CONFIG_DIR/zaro-evolution-state.json"
CORE_INTENT="$CONFIG_DIR/zaro-core-intent.md"
LOG="$CONFIG_DIR/ZARO_EVOLUTION_RUNNER.log"
AGENT_FILE="$CONFIG_DIR/agents/zaro-evolve.md"
PID_FILE="${TMPDIR:-/tmp}/zaro-daemon.pid"
RUN_PGID_FILE="${TMPDIR:-/tmp}/zaro-run.pgid"   # process group of the in-flight opencode run
MODEL="opencode/deepseek-v4-flash-free"
SESSION="zaro"
MAX_CYCLES="${MAX_CYCLES:-200}"
REVIEW_INTERVAL="${REVIEW_INTERVAL:-25}"
RUN_TIMEOUT="${RUN_TIMEOUT:-600}"        # max seconds per opencode run (prevents hang)
MCP_KILL_DELAY="${MCP_KILL_DELAY:-1}"    # seconds between SIGTERM and SIGKILL

mkdir -p "$CONFIG_DIR"
touch "$LOG"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Reap a whole process group (TERM then KILL). Scoped to ONE opencode run's
# group — catches orphaned MCP children reparented to init, but never touches
# other opencode sessions on the host. Replaces the old host-wide `pgrep -f`
# + `sudo kill` sweeps that could kill unrelated processes.
reap_process_group() {
    local pgid="$1"
    [ -z "$pgid" ] && return 0
    kill -TERM -- -"$pgid" 2>/dev/null || true
    sleep "$MCP_KILL_DELAY"
    kill -KILL -- -"$pgid" 2>/dev/null || true
    return 0
}

# Run `opencode run` isolated in its own process group so its leftover children
# can be reaped without a host-wide sweep. Sets global RUN_OUTPUT; returns the
# run's exit status. Records the group id in RUN_PGID_FILE so stop/interrupt
# handlers can reap an in-flight run.
run_opencode_scoped() {
    local prompt="$1"
    local outfile status=0
    outfile=$(mktemp)
    setsid timeout "$RUN_TIMEOUT" opencode run \
        --model "$MODEL" \
        --auto \
        --print-logs \
        "$prompt" >"$outfile" 2>&1 &
    local pgid=$!                       # setsid child is its own group leader; pgid == pid
    echo "$pgid" > "$RUN_PGID_FILE"
    wait "$pgid" || status=$?
    reap_process_group "$pgid"
    rm -f "$RUN_PGID_FILE"
    RUN_OUTPUT=$(cat "$outfile")
    rm -f "$outfile"
    return "$status"
}

# ─── State helpers ───────────────────────────────────────────────

init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"last_review_milestone":0,"last_review_at":null,"cycles_completed":0,"reviews":[]}' > "$STATE_FILE"
        return
    fi
    # Migrate state files that predate the monotonic cycle counter: seed
    # cycles_completed from the count of already-studied topics so the review
    # cadence stays aligned with reality (finding #4).
    STATE_FILE="$STATE_FILE" CURRICULUM="$CURRICULUM" python3 - <<'PY'
import json, os
sf = os.environ['STATE_FILE']
with open(sf) as f:
    s = json.load(f)
if 'cycles_completed' not in s:
    try:
        with open(os.environ['CURRICULUM']) as cf:
            studied = sum(1 for t in json.load(cf)['topics'] if t.get('studied'))
    except Exception:
        studied = s.get('last_review_milestone', 0)
    s['cycles_completed'] = studied
    with open(sf, 'w') as f:
        json.dump(s, f, indent=2)
PY
}

# Review cadence is driven by a monotonic count of completed cycles, NOT by
# topic id — get_next_topic processes topics thin-domain-first, so ids are
# non-monotonic and can't gate the cadence (finding #4).
needs_review() {
    STATE_FILE="$STATE_FILE" REVIEW_INTERVAL="$REVIEW_INTERVAL" python3 - <<'PY'
import json, os
with open(os.environ['STATE_FILE']) as f:
    s = json.load(f)
interval = int(os.environ['REVIEW_INTERVAL'])
done = s.get('cycles_completed', 0)
last = s.get('last_review_milestone', 0)
print('yes' if done - last >= interval else 'no')
PY
}

get_cycles_completed() {
    STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json, os
with open(os.environ['STATE_FILE']) as f:
    print(json.load(f).get('cycles_completed', 0))
PY
}

incr_cycles_completed() {
    STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json, os
sf = os.environ['STATE_FILE']
with open(sf) as f:
    s = json.load(f)
s['cycles_completed'] = s.get('cycles_completed', 0) + 1
with open(sf, 'w') as f:
    json.dump(s, f, indent=2)
PY
}

# Model-supplied strings (summary) are passed via argv into a QUOTED heredoc,
# so nothing from agent output is ever evaluated as shell or python source
# (finding #2 — was a `python3 -c "...'$summary'..."` injection).
mark_review_done() {
    local milestone="$1" checked="$2" corrected="$3" summary="$4"
    STATE_FILE="$STATE_FILE" python3 - "$milestone" "$checked" "$corrected" "$summary" <<'PY'
import json, datetime, os, sys
milestone, checked, corrected, summary = sys.argv[1:5]
sf = os.environ['STATE_FILE']
with open(sf) as f:
    s = json.load(f)
s['last_review_milestone'] = int(milestone)
s['last_review_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
s['reviews'].append({
    'milestone': int(milestone),
    'at': s['last_review_at'],
    'principles_checked': int(checked or 0),
    'drift_corrected': int(corrected or 0),
    'summary': summary,
})
with open(sf, 'w') as f:
    json.dump(s, f, indent=2)
PY
}

get_last_review_milestone() {
    STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json, os
with open(os.environ['STATE_FILE']) as f:
    print(json.load(f).get('last_review_milestone', 0))
PY
}

get_next_topic() {
    python3 -c "
import json, re
with open('$CURRICULUM') as f:
    data = json.load(f)

# Count existing sections per domain in personality
try:
    with open('$CONFIG_DIR/ZARO_PERSONALITY.md') as pf:
        ptext = pf.read()
    domain_counts = {}
    for m in re.finditer(r'<!-- domain:\s*(.*?)\s*-->', ptext, re.I):
        d = m.group(1).lower().strip()
        domain_counts[d] = domain_counts.get(d, 0) + 1
except:
    domain_counts = {}

# Collect unstudied topics with their domain priority
unstudied = [t for t in data['topics'] if not t.get('studied')]
# Sort by thin domain first (fewer existing sections = higher priority), then by id
unstudied.sort(key=lambda t: (domain_counts.get(t.get('domain', '').lower().strip(), 0), t['id']))

if unstudied:
    print(json.dumps(unstudied[0]))
else:
    print('DONE')
"
}

count_done() {
    python3 -c "
import json
with open('$CURRICULUM') as f:
    data = json.load(f)
c = sum(1 for t in data['topics'] if t.get('studied'))
t = len(data['topics'])
print(f'{c}/{t}')
"
}

run_cycle() {
    local topic_json="$1"
    local id book query focus domain
    id=$(echo "$topic_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    book=$(echo "$topic_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('book',''))")
    query=$(echo "$topic_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('query',''))")
    focus=$(echo "$topic_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('focus',''))")
    domain=$(echo "$topic_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('domain',''))")

    # Coherence check every REVIEW_INTERVAL completed cycles (monotonic counter)
    if [ "$(needs_review)" = "yes" ]; then
        _run_coherence_review "$(get_cycles_completed)"
    fi

    log "=== Cycle #$id: $book ($domain) ==="
    log "Focus: $focus"

    AGENT_INSTRUCTIONS=$(cat "$AGENT_FILE")

    local retries=0
    local max_retries=5
    local status=1
    local run_output session_id

    while [ "$status" -ne 0 ] && [ "$retries" -le "$max_retries" ]; do
        if [ "$retries" -gt 0 ]; then
            local backoff=$(( 2 ** (retries - 1) ))
            [ "$backoff" -gt 60 ] && backoff=60
            log "Retry $retries/$max_retries after ${backoff}s backoff..."
            sleep "$backoff"
        fi

        status=0
        run_opencode_scoped "Mode: study
Topic ID: $id
Book: $book
Domain: $domain
Focus: $focus
Search Query: $query

$AGENT_INSTRUCTIONS" || status=$?
        run_output="$RUN_OUTPUT"
        echo "$run_output" | tee -a "$LOG"

        session_id=$(echo "$run_output" | grep -oP 'session\.id=ses_\w+' | head -1 | sed 's/session\.id=//')
        retries=$((retries + 1))
    done

    if [ "$status" -ne 0 ]; then
        log "WARNING: Cycle $id failed after $max_retries retries"
    fi

    # Cleanup session from DB to prevent bloat
    if [ -n "$session_id" ]; then
        log "Cleaning up session $session_id from database"
        delete_session "$session_id"
    fi

    # Advance the monotonic cycle counter that drives review cadence (#4).
    # A failed state write must not kill the daemon (set -e decoupling, #2).
    incr_cycles_completed || log "WARNING: cycle-counter update failed (non-fatal)"

    log "Cycle #$id complete. Progress: $(count_done)"
}

delete_session() {
    local sid="$1"
    python3 -c "
import sqlite3, sys
db = '$HOME/.local/share/opencode/opencode.db'
sid = '$sid'
try:
    conn = sqlite3.connect(db)
    conn.execute('PRAGMA foreign_keys = OFF')
    ph = '?'
    for table, fk in [('message','session_id'),('todo','session_id'),
                       ('session_message','session_id'),('session_input','session_id'),
                       ('session_context_epoch','session_id'),('session_share','session_id')]:
        conn.execute(f'DELETE FROM {table} WHERE {fk}={ph}', (sid,))
    conn.execute('DELETE FROM session WHERE id=?', (sid,))
    conn.commit()
    conn.close()
    print(f'Deleted session {sid}')
except Exception as e:
    print(f'Session cleanup failed (non-fatal): {e}', file=sys.stderr)
"
}

_run_coherence_review() {
    local milestone="$1"
    local last_review
    last_review=$(get_last_review_milestone)

    log "=== Coherence Review at milestone $milestone ==="
    log "Reviewing principles added since milestone $last_review"

    AGENT_INSTRUCTIONS=$(cat "$AGENT_FILE")

    local retries=0
    local max_retries=3
    local status=1
    local review_output=""
    while [ "$status" -ne 0 ] && [ "$retries" -le "$max_retries" ]; do
        if [ "$retries" -gt 0 ]; then
            local backoff=$(( 2 ** (retries - 1) ))
            [ "$backoff" -gt 60 ] && backoff=60
            log "Review retry $retries/$max_retries after ${backoff}s backoff..."
            sleep "$backoff"
        fi

        status=0
        run_opencode_scoped "Mode: review
Milestone: $milestone
Last review milestone: $last_review
Core intent file: $CORE_INTENT

$AGENT_INSTRUCTIONS" || status=$?
        review_output="$RUN_OUTPUT"
        echo "$review_output" | tee -a "$LOG"
        retries=$((retries + 1))
    done

    if [ "$status" -ne 0 ]; then
        log "WARNING: Coherence review at milestone $milestone failed after $max_retries retries"
    fi

    # Extract review stats for state tracking. The agent's report block emits
    # "Checked: N", "Corrected: N", "Status: PASS|CORRECTED" and "Summary: ..."
    # (the Summary line is required by agents/zaro-evolve.md Phase 5, finding #7).
    local checked corrected summary
    checked=$(echo "$review_output" | grep -oP 'Checked:\s*\K\d+' | head -1)
    corrected=$(echo "$review_output" | grep -oP 'Corrected:\s*\K\d+' | head -1)
    summary=$(echo "$review_output" | grep -oP 'Summary:\s*\K.+' | head -1)
    # Fall back to the Status line if no Summary was emitted, then a placeholder.
    [ -z "$summary" ] && summary=$(echo "$review_output" | grep -oP 'Status:\s*\K.+' | head -1)
    checked="${checked:-0}"
    corrected="${corrected:-0}"
    summary="${summary:-Review completed}"

    mark_review_done "$milestone" "$checked" "$corrected" "$summary" \
        || log "WARNING: review state write failed (non-fatal)"
    log "Coherence review at milestone $milestone complete. Checked: $checked, Corrected: $corrected"
}

# ─── Commands ───────────────────────────────────────────────────

cmd_start() {
    local interval="${1:-3600}"
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log "Session $SESSION already exists. Attach: tmux attach -t $SESSION"
        exit 1
    fi
    log "Starting Zaro Evolution Daemon (interval: ${interval}s, max: ${MAX_CYCLES} cycles)"
    tmux new-session -d -s "$SESSION" -n evolve "$0" _run_loop "$interval"
    log "Daemon started in tmux session '$SESSION'"
    log "Attach: tmux attach -t $SESSION"
    log "Detach: Ctrl+B, D"
    log "Stop: $0 stop"
}

cmd_stop() {
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux send-keys -t "$SESSION" C-c 2>/dev/null
        sleep 1
        tmux kill-session -t "$SESSION" 2>/dev/null
    fi
    # setsid detaches each run from the tmux tree, so reap the in-flight run's
    # process group explicitly (scoped — never a host-wide sweep).
    [ -f "$RUN_PGID_FILE" ] && reap_process_group "$(cat "$RUN_PGID_FILE")"
    rm -f "$RUN_PGID_FILE"
    log "Daemon stopped."
}

cmd_status() {
    local done_info
    done_info=$(count_done)
    local last_entry
    last_entry=$(tail -5 "$LOG" 2>/dev/null || echo "No log yet")
    local last_review_info
    last_review_info=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
lr = s.get('last_review_milestone', 0)
at = s.get('last_review_at', 'never')
reviews = s.get('reviews', [])
last = reviews[-1] if reviews else {}
print(f'{lr}|{at}|' + json.dumps(last))
" 2>/dev/null || echo "0|never|{}")
    local last_review_milestone last_review_at last_summary
    last_review_milestone=$(echo "$last_review_info" | cut -d'|' -f1)
    last_review_at=$(echo "$last_review_info" | cut -d'|' -f2)
    last_summary=$(echo "$last_review_info" | cut -d'|' -f3- | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || echo "")

    echo "=== Zaro Evolution Status ==="
    echo "Curriculum: $done_info topics studied"
    echo "Review: milestone $last_review_milestone at $last_review_at"
    [ -n "$last_summary" ] && echo "  Last: $last_summary"
    echo ""

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "Daemon: RUNNING (tmux session: $SESSION)"
        local uptime
        uptime=$(tmux list-sessions -F "#{session_name} #{session_created}" 2>/dev/null | grep "^$SESSION" | awk '{print $2}' | xargs -I{} date -d "@{}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        echo "Started: $uptime"
    else
        echo "Daemon: STOPPED"
    fi

    echo ""
    echo "--- Last log entries ---"
    echo "$last_entry"
}

cmd_once() {
    init_state   # ensure cycles_completed exists before run_cycle reads/increments it
    local topic
    topic=$(get_next_topic)
    if [ "$topic" = "DONE" ] || [ -z "$topic" ]; then
        log "All topics studied! Evolution complete."
        exit 0
    fi
    run_cycle "$topic"
}

cmd_study() {
    init_state   # ensure cycles_completed exists before run_cycle reads/increments it
    local topic_id="$1"
    if [ -z "$topic_id" ]; then
        log "Usage: $0 study <topic_id>"
        exit 1
    fi
    local topic_json
    topic_json=$(python3 -c "
import json, sys
with open('$CURRICULUM') as f:
    data = json.load(f)
for t in data['topics']:
    if t['id'] == $topic_id:
        print(json.dumps(t))
        break
")
    if [ -z "$topic_json" ]; then
        log "Topic ID $topic_id not found in curriculum"
        exit 1
    fi
    run_cycle "$topic_json"
}

cmd_reset() {
    python3 -c "
import json
with open('$CURRICULUM') as f:
    data = json.load(f)
for t in data['topics']:
    t.pop('studied', None)
    t.pop('studied_at', None)
with open('$CURRICULUM', 'w') as f:
    json.dump(data, f, indent=2)
"
    echo '{"last_review_milestone":0,"last_review_at":null,"reviews":[]}' > "$STATE_FILE"
    log "Curriculum reset. All topics unstudied. Review state cleared."
}

cmd_review() {
    init_state
    local last_milestone
    last_milestone=$(get_last_review_milestone)
    local next_milestone=$((last_milestone + REVIEW_INTERVAL))
    _run_coherence_review "$next_milestone"
}

# ─── Internal: Run loop (called by tmux) ────────────────────────

_run_loop() {
    local interval="$1"
    local cycle=0

    # Self-cleanup on interrupt: reap the in-flight run's process group (scoped),
    # then kill the tmux session.
    trap 'log "Daemon interrupted."; [ -f "$RUN_PGID_FILE" ] && reap_process_group "$(cat "$RUN_PGID_FILE")"; rm -f "$RUN_PGID_FILE"; tmux kill-session -t "$SESSION" 2>/dev/null; exit 1' INT TERM

    init_state

    log "=== Zaro Evolution Daemon started ==="
    log "Interval: ${interval}s | Model: $MODEL | Max: $MAX_CYCLES cycles"
    log "Curriculum: $CURRICULUM"
    log "---"

    while [ "$cycle" -lt "$MAX_CYCLES" ]; do
        local topic
        topic=$(get_next_topic)

        if [ "$topic" = "DONE" ] || [ -z "$topic" ]; then
            log "All topics complete! Zaro evolution finished."
            log "Total daemon cycles: $cycle"
            tmux kill-session -t "$SESSION" 2>/dev/null
            exit 0
        fi

        cycle=$((cycle + 1))
        run_cycle "$topic"

        if [ "$cycle" -lt "$MAX_CYCLES" ]; then
            local next
            next=$(get_next_topic)
            if [ "$next" != "DONE" ] && [ -n "$next" ]; then
                log "Sleeping ${interval}s until cycle #$(echo "$next" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")..."
                sleep "$interval"
            fi
        fi
    done

    log "Reached max $MAX_CYCLES cycles. Stopping."
    tmux kill-session -t "$SESSION" 2>/dev/null
}

# ─── Main ───────────────────────────────────────────────────────

case "${1:-status}" in
    start)
        cmd_start "${2:-3600}"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    once)
        cmd_once
        ;;
    study)
        cmd_study "$2"
        ;;
    reset)
        cmd_reset
        ;;
    review)
        cmd_review
        ;;
    _run_loop)
        _run_loop "${2:-3600}"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|once|reset|review} [interval_seconds]"
        echo "  start [N]   Start daemon (N=seconds between cycles, default 3600)"
        echo "  stop        Stop daemon"
        echo "  status      Show progress and daemon state"
        echo "  once        Run one cycle now"
        echo "  review      Run coherence review now"
        echo "  reset       Reset curriculum and review state"
        exit 1
        ;;
esac
