#!/usr/bin/env bash
# Guard: scripts/lib/strata_metrics.py, the one reader of a Strata server's /metrics JSON.
#
# Strata writes its per-request lines to a log file inside the container, not to `docker logs`,
# so the health, verify-full and bench arms for Strata read /metrics instead. A reader that
# returned "0 drafts" for a document it could not read would make a dead drafter and a broken
# probe look the same, so every way of failing to read must exit 3, distinct from a clean read.
#
# Fixtures are served by a local http.server on a free port, so no Strata server is needed:
#   1. recent: sums the newest requests (decode / prefill tok/s, acceptance, hit rate, engine);
#   2. no drafts offered: accept_rate is EMPTY, not 0 (the consumer decides what that means);
#   3. delta between two snapshots, and a restart between them (fewer requests) refused;
#   4. negative controls, each exit 3: not JSON, JSON without engine.version, unreachable;
#   5. soak-helper's Strata log signature: the per-request 'done' line, not the progress line.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
SM="scripts/lib/strata_metrics.py"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }

work="$(mktemp -d)"
server_pid=""
cleanup() { [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "$work/ok" "$work/nodrafts" "$work/notjson" "$work/foreign"
cat > "$work/ok/metrics" <<'JSON'
{"engine": {"version": "0.1.43.1", "kv": "int8", "max_context": 131072, "expert_slots": 8746},
 "totals": {"requests": 2, "output_tokens": 300, "decode_ms": 3000, "prompt_tokens": 1100, "reused": 100,
            "prompt_ms": 500, "drafts_offered": 200, "drafts_accepted": 150},
 "requests": [
   {"output_tokens": 200, "decode_ms": 2000, "prompt_read": 600, "prompt_ms": 300,
    "drafts_offered": 150, "drafts_accepted": 120, "hit_rate": 0.9},
   {"output_tokens": 100, "decode_ms": 1000, "prompt_read": 400, "prompt_ms": 200,
    "drafts_offered": 50, "drafts_accepted": 30, "hit_rate": 0.8}]}
JSON
cat > "$work/nodrafts/metrics" <<'JSON'
{"engine": {"version": "0.1.43.1"}, "totals": {"requests": 1},
 "requests": [{"output_tokens": 50, "decode_ms": 500, "prompt_read": 10, "prompt_ms": 10,
               "drafts_offered": 0, "drafts_accepted": 0}]}
JSON
echo '<html>not metrics</html>' > "$work/notjson/metrics"
echo '{"totals": {"requests": 3}}' > "$work/foreign/metrics"

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/ok/metrics" && break
  sleep 0.1
done
base="http://127.0.0.1:$port"

# 1. recent
out="$(python3 "$SM" recent "$base/ok")"; r=$?
want="requests=2 output_tokens=300 decode_tok_s=100.00 prefill_tok_s=2000.00 drafts_offered=200 drafts_accepted=150 accept_rate=0.7500 hit_rate=0.850 version=0.1.43.1 kv=int8 max_context=131072 expert_slots=8746"
[[ $r -eq 0 && "$(tr '\n' ' ' <<<"$out" | sed 's/ $//')" == "$want" ]] \
  && ok "recent sums the newest requests (tok/s, acceptance, hit rate, engine)" \
  || bad "recent: rc=$r, got: $(tr '\n' ' ' <<<"$out")"
out="$(python3 "$SM" recent "$base/ok" 1)"
command grep -qx 'accept_rate=0.8000' <<<"$out" && command grep -qx 'requests=1' <<<"$out" \
  && ok "recent N takes only the newest N (newest first)" || bad "recent 1: $(tr '\n' ' ' <<<"$out")"

# 2. no drafts offered
out="$(python3 "$SM" recent "$base/nodrafts")"; r=$?
[[ $r -eq 0 ]] && command grep -qx 'accept_rate=' <<<"$out" && command grep -qx 'drafts_offered=0' <<<"$out" \
  && ok "no drafts offered: accept_rate empty, drafts_offered=0 (not a fake 0% or 100%)" \
  || bad "no drafts: rc=$r, got: $(tr '\n' ' ' <<<"$out")"

# 3. delta, and a restart between snapshots
python3 "$SM" snapshot "$base/nodrafts" > "$work/before.json" && python3 "$SM" snapshot "$base/ok" > "$work/after.json"
out="$(python3 "$SM" delta "$work/before.json" "$work/after.json")"; r=$?
command grep -qx 'requests=1' <<<"$out" && command grep -qx 'decode_tok_s=100.00' <<<"$out" \
  && command grep -qx 'accept_rate=0.7500' <<<"$out" \
  && ok "delta between two snapshots" || bad "delta: rc=$r, got: $(tr '\n' ' ' <<<"$out")"
python3 "$SM" delta "$work/after.json" "$work/before.json" >/dev/null 2>&1; r=$?
[[ $r -eq 3 ]] && ok "delta refuses a restart between snapshots (fewer requests): exit 3" || bad "restart: exit $r, want 3"

# 4. negative controls: every failure to read is exit 3
for case in notjson foreign; do
  python3 "$SM" recent "$base/$case" >/dev/null 2>&1; r=$?
  [[ $r -eq 3 ]] && ok "$case /metrics: exit 3" || bad "$case /metrics: exit $r, want 3"
done
python3 "$SM" recent "http://127.0.0.1:1" >/dev/null 2>&1; r=$?
[[ $r -eq 3 ]] && ok "unreachable server: exit 3" || bad "unreachable: exit $r, want 3"
python3 "$SM" recent >/dev/null 2>&1; r=$?
[[ $r -eq 2 ]] && ok "bad usage: exit 2" || bad "bad usage: exit $r, want 2"

# 5. soak-helper reads Strata's per-request docker-logs line, and not its progress line
got="$(python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("sh", "scripts/soak-helper.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
done = "[strata] done: 231 tokens in 3 s (107.7 tok/s) (stop, cancel=False), expert cache 74.7% hit"
progress = "[strata] answering: 58 of max 1500 tokens, 103.0 tok/s, 1 s"
print(m.engine_rate_from_logs(progress + "\n" + done), m.engine_rate_from_logs(progress))
PY
)"
[[ "$got" == "(107.7, 'strata-log') (None, '')" ]] \
  && ok "soak-helper: Strata 'done' line is an engine-reported decode rate; the progress line is not" \
  || bad "soak-helper Strata signature: got $got"

if [[ $rc -eq 0 ]]; then echo "PASS: test-strata-metrics"; else echo "FAIL: test-strata-metrics"; fi
exit $rc
