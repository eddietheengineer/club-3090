#!/usr/bin/env bash
# Guard: the DeepSeek-V4.1-Flash Project Maya recipe (models/deepseek-v4.1-flash-1017/strata-maya/launcher/) writes
# club-3090's launch settings into maya-ds4.json at every boot (ds4_prepare.py config() through ds4_settings.py),
# and prepares the pack the way the slug needs. Runs the launcher's own functions against scratch folders (no
# /opt/maya, no weights):
#   1. no settings: effort high, sampling 1.0 / 1.0, name deepseek-v4.1-flash, maya-ds4 with --tp 1 (a layer
#      split on two GPUs), --vision off, --dspark on and a --cpu-threads from threads();
#   2. each setting lands on Maya's key; medium / xhigh become high / max; ENABLE_THINKING=false wins;
#      THREADS sets --cpu-threads; KV / SPEC_N write nothing (maya-ds4 has neither);
#   3. the config is rewritten from scratch each time, so a setting removed is gone;
#   4. a bad value exits 2 from `validate` and stops ds4_prepare.py's main() before it looks at any file;
#   5. threads(): 3/4 of the CPUs, at most one a physical core, at least 1 (and the cap read from sysfs);
#   6. fix_dspark(): writes DeepSeek-V4.1-Flash's DSpark geometry only where the pack says 0, keeps the rest;
#   7. verify(): a file whose SHA-256 is wrong stops the boot; a matching set is recorded and not hashed again;
#   8. every key a setting writes has evidence that the pinned Maya reads it (engine_config_reads.py check).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the launcher folder is mounted into the container: leave no __pycache__
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
L="models/deepseek-v4.1-flash-1017/strata-maya/launcher"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
SETTINGS="REASONING_EFFORT ENABLE_THINKING THINKING_BUDGET MAX_TOKENS KV SPEC_N TEMP TOP_P TOP_K MIN_P PRESENCE_PENALTY REPEAT_PENALTY SERVED_NAME THREADS"
clean() { for v in $SETTINGS; do printf -- '-u %s ' "$v"; done; }
# config() for ista-iq2-xxs into $work/ista-iq2-xxs/maya-ds4.json, with the given settings
write() {
  env $(clean) "$@" python3 - "$L" "$work" <<'PY'
import sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import ds4_prepare
d = Path(sys.argv[2]) / "ista-iq2-xxs"; d.mkdir(exist_ok=True)
ds4_prepare.config("ista-iq2-xxs", d, d / "pack", types.SimpleNamespace(gpus="0,1", tp=1, context=65536))
PY
}
get() { python3 -c "import json,sys; c=json.load(open('$work/ista-iq2-xxs/maya-ds4.json')); a=c['args']; print(eval(sys.argv[1]))" "$1"; }
arg() { get "a[a.index('$1')+1] if '$1' in a else None"; }

echo "== 1. no settings"
write >/dev/null || bad "config() failed with no settings"
[[ "$(get 'c["reasoning_effort"]')" == high ]] && ok "effort high (Maya's own for DeepSeek)" || bad "effort: $(get 'c.get("reasoning_effort")')"
[[ "$(get 'c["sampling"]')" == "{'temperature': 1.0, 'top_p': 1.0}" ]] && ok "sampling 1.0 / 1.0" || bad "sampling: $(get 'c["sampling"]')"
[[ "$(get 'c["model_name"]')" == deepseek-v4.1-flash ]] && ok "served as deepseek-v4.1-flash" || bad "model_name: $(get 'c.get("model_name")')"
[[ "$(get 'c["exe"]')" == /opt/maya/build/maya-ds4 ]] && ok "exe maya-ds4" || bad "exe: $(get 'c["exe"]')"
[[ "$(arg --tp) $(arg --vision) $(arg --dspark) $(arg --max-context)" == "1 off on 65536" ]] \
  && ok "--tp 1 (layer split), --vision off, --dspark on, --max-context 65536" || bad "args: $(get 'a')"
want="$(env $(clean) python3 -c "import sys; sys.path.insert(0, '$L'); import ds4_settings; print(ds4_settings.threads())")"
[[ "$(arg --cpu-threads)" == "$want" && "$want" -ge 1 ]] && ok "--cpu-threads $want = threads()" || bad "--cpu-threads $(arg --cpu-threads), threads() $want"
[[ "$(get '"thinking_budget" in c or "--kv" in a or "--spec" in a')" == False ]] \
  && ok "no thinking_budget / --kv / --spec: Maya's own" || bad "an unset setting was written"
[[ "$(get 'c["gpu"]') $(get 'c["log"].endswith("/ista-iq2-xxs/maya-ds4.log")')" == "[0, 1] True" ]] \
  && ok "GPUs [0, 1], the engine log in the quant's folder" || bad "gpu/log: $(get 'c["gpu"], c["log"]')"

echo "== 2. each setting reaches Maya's key"
write REASONING_EFFORT=medium THINKING_BUDGET=8192 TEMP=0.7 TOP_P=0.9 TOP_K=40 MIN_P=0.05 PRESENCE_PENALTY=0.5 \
      REPEAT_PENALTY=1.1 THREADS=7 KV=int8 SPEC_N=3 MAX_TOKENS=4096 >/dev/null || bad "config() failed"
[[ "$(get 'c["reasoning_effort"]')" == high ]] && ok "medium -> high" || bad "effort: $(get 'c["reasoning_effort"]')"
[[ "$(get 'c["thinking_budget"]')" == 8192 ]] && ok "thinking_budget" || bad "budget: $(get 'c.get("thinking_budget")')"
[[ "$(arg --cpu-threads)" == 7 ]] && ok "THREADS=7 -> --cpu-threads 7" || bad "threads: $(get 'a')"
[[ "$(get '"--kv" in a or "--spec" in a or "max_tokens" in c')" == False ]] \
  && ok "KV / SPEC_N / MAX_TOKENS write nothing (maya-ds4 has no --kv or depth flag)" || bad "KV/SPEC_N/MAX_TOKENS written: $(get 'a')"
[[ "$(get 'sorted(c["sampling"].items())')" == "[('min_p', 0.05), ('presence_penalty', 0.5), ('repetition_penalty', 1.1), ('temperature', 0.7), ('top_k', 40), ('top_p', 0.9)]" ]] \
  && ok "sampler settings" || bad "sampling: $(get 'c["sampling"]')"
write REASONING_EFFORT=xhigh >/dev/null; [[ "$(get 'c["reasoning_effort"]')" == max ]] && ok "xhigh -> max" || bad "xhigh"
write SERVED_NAME=llm >/dev/null; [[ "$(get 'c["model_name"]')" == llm ]] && ok "SERVED_NAME=llm -> model_name llm" || bad "served name: $(get 'c["model_name"]')"
out="$(write ENABLE_THINKING=false REASONING_EFFORT=low)"
[[ "$(get 'c["reasoning_effort"]')" == none ]] && command grep -q "ENABLE_THINKING=false wins" <<<"$out" \
  && ok "ENABLE_THINKING=false -> none, with a note" || bad "thinking off: $out"

echo "== 3. a removed setting is gone"
write >/dev/null
[[ "$(get 'c["reasoning_effort"], "thinking_budget" in c, c["model_name"], a[a.index("--cpu-threads")+1]')" == "('high', False, 'deepseek-v4.1-flash', '$want')" ]] \
  && ok "back to the defaults" || bad "a setting lingered: $(get 'c["reasoning_effort"], "thinking_budget" in c, c["model_name"], a')"

echo "== 4. a bad value"
for probe in REASONING_EFFORT=minimal REASONING_EFFORT=75 ENABLE_THINKING=off THINKING_BUDGET=-1 TEMP=x TOP_P=0 \
             TOP_K=65 MIN_P=2 PRESENCE_PENALTY=-1 REPEAT_PENALTY=0 THREADS=0 THREADS=four; do
  err="$(env $(clean) "$probe" python3 "$L/ds4_settings.py" validate 2>&1)"; r=$?
  [[ $r -eq 2 && "$err" == *"${probe%%=*}"* ]] && ok "$probe refused" || bad "$probe: rc=$r $err"
done
err="$(env $(clean) "SERVED_NAME=my model" python3 "$L/ds4_settings.py" validate 2>&1)"; r=$?
[[ $r -eq 2 && "$err" == *SERVED_NAME* ]] && ok "SERVED_NAME with a space refused" || bad "SERVED_NAME=my model: rc=$r $err"
err="$(env $(clean) REASONING_EFFORT=minimal python3 "$L/ds4_prepare.py" --tag ista-iq2-xxs --src "$work/nowhere" \
       --dspark "$work/nowhere" --data "$work" 2>&1)"; r=$?
[[ $r -ne 0 && "$err" == *REASONING_EFFORT* && "$err" != *missing* ]] \
  && ok "ds4_prepare.py stops on it before looking at the files" || bad "main(): rc=$r $err"
err="$(env $(clean) python3 "$L/ds4_prepare.py" --tag ista-iq2-xxs --src "$work/nowhere" --dspark "$work/nowhere" \
       --data "$work" 2>&1)"; r=$?
[[ $r -ne 0 && "$err" == *missing:* && "$err" == *setup.sh* ]] \
  && ok "missing weights: stops, names the files and the download" || bad "missing weights: rc=$r $err"

echo "== 5. threads(): 3/4 of the CPUs, at most one a physical core"
out="$(python3 - "$L" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import ds4_settings as s
print(s.threads(list(range(32)), 32), s.threads(list(range(32)), 16), s.threads(list(range(16)), 8),
      s.threads(list(range(32)), None), s.threads([0], 1), s.threads(list(range(4)), 4))
PY
)"
# 32 cores no SMT -> 24; 16c/32t -> 16; 8c/16t -> 8; topology unknown -> 3/4 of 32 = 24; 1 CPU -> 1; 4 cores -> 3
[[ "$out" == "24 16 8 24 1 3" ]] && ok "32c -> 24, 16c/32t -> 16, 8c/16t -> 8, unknown -> 24, 1 -> 1, 4 -> 3" || bad "threads(): $out"
sysfs="$work/sysfs"
for c in 0 1 2 3; do mkdir -p "$sysfs/cpu$c/topology"; echo $((c / 2)) > "$sysfs/cpu$c/topology/core_id"; echo 0 > "$sysfs/cpu$c/topology/physical_package_id"; done
out="$(python3 - "$L" "$sysfs" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import ds4_settings as s
print(s._physical_cores([0, 1, 2, 3], sys.argv[2]), s._physical_cores([0, 1, 9], sys.argv[2]))
PY
)"
[[ "$out" == "2 None" ]] && ok "sysfs: 4 SMT siblings on 2 cores -> 2; an unreadable CPU -> None (no cap)" || bad "_physical_cores: $out"

echo "== 6. fix_dspark(): only where the pack says 0"
mkdir -p "$work/pack0" "$work/packok"
printf 'hidden_size 5120\ndspark_block_size 0\ndspark_noise_token_id 0\ndspark_markov_rank 0\ndspark_n_routed_experts 0\ndspark_num_experts_per_tok 0\ndspark_target_layer_ids 37,38,39\nformat gguf\n' > "$work/pack0/ds4.txt"
printf 'hidden_size 5120\ndspark_block_size 4\ndspark_noise_token_id 7\ndspark_markov_rank 8\ndspark_n_routed_experts 64\ndspark_num_experts_per_tok 2\ndspark_target_layer_ids 37,38,39\n' > "$work/packok/ds4.txt"
cp "$work/packok/ds4.txt" "$work/packok.orig"
out="$(python3 - "$L" "$work" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import ds4_prepare
w = Path(sys.argv[2])
ds4_prepare.fix_dspark(w / "pack0")
ds4_prepare.fix_dspark(w / "packok")
PY
)"
[[ "$(cat "$work/pack0/ds4.txt")" == "$(printf 'hidden_size 5120\ndspark_block_size 5\ndspark_noise_token_id 128799\ndspark_markov_rank 256\ndspark_n_routed_experts 128\ndspark_num_experts_per_tok 3\ndspark_target_layer_ids 37,38,39\nformat gguf')" ]] \
  && command grep -q 'DSpark geometry missing' <<<"$out" && ok "zeros -> DeepSeek-V4.1-Flash's geometry, with a note; the other lines kept" \
  || bad "pack0: $(cat "$work/pack0/ds4.txt") / $out"
cmp -s "$work/packok/ds4.txt" "$work/packok.orig" && ok "a pack that has its geometry is left alone" || bad "packok changed: $(cat "$work/packok/ds4.txt")"

echo "== 7. verify(): the SHA-256 table stops a damaged file; a match is recorded"
out="$(python3 - "$L" "$work" <<'PY' 2>&1
import hashlib, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import ds4_prepare as p
w = Path(sys.argv[2]) / "v"; w.mkdir()
f = w / "a.gguf"; f.write_bytes(b"good")
p.WEIGHTS["t"] = {"gguf": {"a.gguf": hashlib.sha256(b"good").hexdigest()}, "dspark": {}}
p.verify("t", [f], w)                               # matches: recorded
calls = []
p.sha256 = lambda x: calls.append(x) or "never"     # a second verify must not hash again
p.verify("t", [f], w)
print("rehashed" if calls else "not rehashed")
f.write_bytes(b"bad!")                               # same size, different bytes + a new mtime
p.sha256 = lambda x: hashlib.sha256(x.read_bytes()).hexdigest()
p.verify("t", [f], w)
print("NOT STOPPED")
PY
)"
command grep -q "every file matches" <<<"$out" && command grep -q "not rehashed" <<<"$out" \
  && ok "a matching file is recorded and not hashed again" || bad "verify record: $out"
command grep -q "SHA-256 mismatch" <<<"$out" && ! command grep -q "NOT STOPPED" <<<"$out" \
  && ok "a changed file is hashed again and stops the boot" || bad "verify mismatch: $out"

echo "== 8. the pinned engine reads every key a setting writes (engine-config-reads.json; no docker)"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/profiles/engine_config_reads.py check --engine strata-maya:ds4 || rc=1

if [[ "$rc" -eq 0 ]]; then echo "test-maya-ds4-config: ok"; else echo "test-maya-ds4-config: FAILED" >&2; fi
exit "$rc"
