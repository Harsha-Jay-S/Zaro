#!/bin/bash
# Zaro smoke test — offline, no tmux / no daemon / no network.
# Verifies the finding-fix set without touching real Zaro state:
#   #1 plugin registered   #2 apostrophe-safe daemon   #3 scoped process reaping
#   #5 per-section RAG gate #6 full domain coverage     + all edited files valid
#   injection budget + no-match noise (post-A/B fix round: digest, no random
#   section on a miss, per-section trim + total-payload cap)
#
# Usage: scripts/zaro-smoke-test.sh   (exit 0 = all pass)

set -u
CONFIG_DIR="$HOME/.config/opencode"
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== T0: edited files parse / valid =="
node --check "$CONFIG_DIR/plugins/zaro.js" 2>/dev/null && ok "zaro.js syntax" || bad "zaro.js syntax"
bash -n "$CONFIG_DIR/scripts/zaro-loop.sh" 2>/dev/null && ok "zaro-loop.sh syntax" || bad "zaro-loop.sh syntax"
for j in opencode.json zaro-domain-map.json zaro-evolution-state.json; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CONFIG_DIR/$j" 2>/dev/null \
    && ok "$j valid json" || bad "$j invalid json"
done

echo "== T1 (#1): zaro.js registered in opencode.json =="
grep -q 'plugins/zaro\.js' "$CONFIG_DIR/opencode.json" && ok "registered" || bad "not registered"

echo "== T2 (#5): per-section RAG threshold gate present =="
grep -q 'filter(s => s.score >= getThresholdForDomain' "$CONFIG_DIR/plugins/zaro.js" \
  && ok "per-section gate present" || bad "per-section gate missing"

echo "== T3 (#6): every curriculum domain has domain-map keywords =="
python3 - "$CONFIG_DIR" <<'PY'
import json, os, sys
cd = sys.argv[1]
cur = set(t['domain'] for t in json.load(open(os.path.join(cd,'zaro-curriculum.json')))['topics'])
dm  = set(json.load(open(os.path.join(cd,'zaro-domain-map.json'))).keys())
missing = sorted(cur - dm)
sys.exit(0 if not missing else (print('missing:', missing) or 1))
PY
[ $? -eq 0 ] && ok "all curriculum domains routed" || bad "domains missing from map"

echo "== T6: injection budget + no-match noise (real production ZaroPlugin, not a stub) =="
node --input-type=module - "$CONFIG_DIR" <<'NODE'
const configDir = process.argv[2];
const { ZaroPlugin } = await import(configDir + '/plugins/zaro.js');
const hooks = await ZaroPlugin();
async function inject(text) {
  const output = {};
  await hooks['chat.message']({ parts: [{ type: 'text', text }] }, output);
  return output.parts?.[0]?.text || '';
}
const onTopic = await inject('help me debug this failing test, I keep hitting the same error');
const offTopic = await inject('what is a good recipe for pasta carbonara');
const offTopicHasSection = /\n### (?!Core Intent)/.test(offTopic);
console.log(`  on-topic: ${onTopic.length} chars | off-topic: ${offTopic.length} chars | off-topic has random section: ${offTopicHasSection}`);
const passed = onTopic.length <= 2100 && offTopic.length <= 1200 && !offTopicHasSection;
process.exit(passed ? 0 : 1);
NODE
[ $? -eq 0 ] && ok "on-topic injection under budget (~500 tokens), off-topic gets digest-only (no random section)" \
             || bad "budget or no-match-noise regression — see output above"

echo "== T4/T5 (#2, #3): sandbox review — apostrophes survive, external MCP survives =="
SB=$(mktemp -d)
mkdir -p "$SB/.config/opencode/scripts" "$SB/.config/opencode/agents" "$SB/bin"
cp "$CONFIG_DIR/scripts/zaro-loop.sh" "$SB/.config/opencode/scripts/"
echo '{"last_review_milestone":0,"last_review_at":null,"cycles_completed":0,"reviews":[]}' \
  > "$SB/.config/opencode/zaro-evolution-state.json"
echo '{"topics":[{"id":1,"domain":"test","book":"Test Book","studied":true}]}' \
  > "$SB/.config/opencode/zaro-curriculum.json"
echo "core intent" > "$SB/.config/opencode/zaro-core-intent.md"
echo "agent instructions" > "$SB/.config/opencode/agents/zaro-evolve.md"

# Stub opencode: emit a review report whose Summary line is full of shell/python
# metacharacters. If any reaches an eval, the daemon dies (old bug).
cat > "$SB/bin/opencode" <<'EOF'
#!/bin/bash
cat <<'OUT'
Coherence Review at milestone 25 complete.
Checked: 3 principles since last review.
Corrected: 1 items of drift.
Status: CORRECTED
Summary: it's Zaro's "self-review"; $(rm -rf /) drift fixed
OUT
EOF
chmod +x "$SB/bin/opencode"

# External process the OLD host-wide sweep WOULD have killed (cmdline "python3 client.py").
echo 'import time; time.sleep(60)' > "$SB/client.py"
( cd "$SB" && exec python3 client.py ) &
EXT_PID=$!
sleep 0.3

set +e
HOME="$SB" PATH="$SB/bin:$PATH" TMPDIR="$SB" \
  bash "$SB/.config/opencode/scripts/zaro-loop.sh" review >"$SB/run.log" 2>&1
RC=$?
set -e 2>/dev/null || true

[ "$RC" -eq 0 ] && ok "daemon survived apostrophe/quote/subshell summary (rc=0)" \
                || bad "daemon exited non-zero (rc=$RC) — see $SB/run.log"

EXPECTED='it'\''s Zaro'\''s "self-review"; $(rm -rf /) drift fixed'
GOT=$(python3 -c "import json;print(json.load(open('$SB/.config/opencode/zaro-evolution-state.json'))['reviews'][-1]['summary'])" 2>/dev/null)
[ "$GOT" = "$EXPECTED" ] && ok "summary stored verbatim (no injection, no mangling)" \
                         || bad "summary mismatch: got [$GOT]"

if kill -0 "$EXT_PID" 2>/dev/null; then ok "external 'python3 client.py' survived (scoped reap)"; else bad "external process was killed (blast radius)"; fi

kill "$EXT_PID" 2>/dev/null || true
rm -rf "$SB"

echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
