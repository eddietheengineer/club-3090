#!/usr/bin/env bash
# Guard: the Project Maya recipe writes club-3090's launch settings into maya.json at every boot
# (models/glm-5.3-flash/strata-maya/launcher/: maya_prepare.py config() through maya_settings.py).
# Runs config() itself against a scratch data folder (no /opt/maya needed for that step):
#   1. no settings: effort max, sampling 1.0 / 0.95, no thinking_budget / --kv (Maya's own);
#   2. each setting lands on Maya's key; medium / xhigh become high / max; ENABLE_THINKING=false wins;
#   3. the config is rewritten from scratch each time, so a setting removed is gone;
#   4. a bad value exits 2 from `validate` and stops maya_prepare.py's main() before any shard work;
#   5. every key a setting writes has evidence that the pinned Maya reads it (engine_config_reads.py check:
#      a new setting needs an entry in engine-config-reads.json);
#   6. "exe" names the image's engine: build/maya (Maya v1.1.16 on), else build/strata, else build/maya.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the launcher folder is mounted into the container: leave no __pycache__
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
L="models/glm-5.3-flash/strata-maya/launcher"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
SETTINGS="REASONING_EFFORT ENABLE_THINKING THINKING_BUDGET MAX_TOKENS KV TEMP TOP_P TOP_K MIN_P PRESENCE_PENALTY REPEAT_PENALTY"
clean() { for v in $SETTINGS; do printf -- '-u %s ' "$v"; done; }
# config() for maya-s into $work/maya-s/maya.json, with the given settings
write() {
  env $(clean) "$@" python3 - "$L" "$work" <<'PY'
import sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import maya_prepare
d = Path(sys.argv[2]) / "maya-s"; d.mkdir(exist_ok=True)
maya_prepare.config("maya-s", d, d / "pack", types.SimpleNamespace(gpus="0,1", context=131072))
PY
}
get() { python3 -c "import json,sys; c=json.load(open('$work/maya-s/maya.json')); print(eval(sys.argv[1]))" "$1"; }

echo "== 1. no settings"
write >/dev/null || bad "config() failed with no settings"
[[ "$(get 'c["reasoning_effort"]')" == max ]] && ok "effort max" || bad "effort: $(get 'c.get("reasoning_effort")')"
[[ "$(get 'c["sampling"]')" == "{'temperature': 1.0, 'top_p': 0.95}" ]] && ok "sampling 1.0 / 0.95" || bad "sampling: $(get 'c["sampling"]')"
[[ "$(get '"thinking_budget" in c or "max_tokens" in c or "--kv" in c["args"]')" == False ]] \
  && ok "no thinking_budget / --kv: Maya's own" || bad "an unset setting was written"

echo "== 2. each setting reaches Maya's key"
write REASONING_EFFORT=medium THINKING_BUDGET=8192 MAX_TOKENS=4096 KV=int8 TEMP=0.7 TOP_P=0.9 TOP_K=40 \
      MIN_P=0.05 PRESENCE_PENALTY=0.5 REPEAT_PENALTY=1.1 >/dev/null || bad "config() failed"
[[ "$(get 'c["reasoning_effort"]')" == high ]] && ok "medium -> high" || bad "effort: $(get 'c["reasoning_effort"]')"
[[ "$(get 'c["thinking_budget"]')" == 8192 ]] && ok "thinking_budget" || bad "budget: $(get 'c.get("thinking_budget")')"
# MAX_TOKENS is not a Maya setting: maya.json's max_tokens is the vision encoder's, so nothing may write it
[[ "$(get '"max_tokens" in c')" == False ]] && ok "MAX_TOKENS ignored (Maya reads no output cap from maya.json)" \
  || bad "max_tokens written into maya.json"
[[ "$(get 'c["args"][c["args"].index("--kv")+1]')" == int8 ]] && ok "KV -> --kv int8" || bad "kv: $(get 'c["args"]')"
[[ "$(get 'sorted(c["sampling"].items())')" == "[('min_p', 0.05), ('presence_penalty', 0.5), ('repetition_penalty', 1.1), ('temperature', 0.7), ('top_k', 40), ('top_p', 0.9)]" ]] \
  && ok "sampler settings" || bad "sampling: $(get 'c["sampling"]')"
write REASONING_EFFORT=xhigh >/dev/null; [[ "$(get 'c["reasoning_effort"]')" == max ]] && ok "xhigh -> max" || bad "xhigh"
out="$(write ENABLE_THINKING=false REASONING_EFFORT=low)"
[[ "$(get 'c["reasoning_effort"]')" == none ]] && command grep -q "ENABLE_THINKING=false wins" <<<"$out" \
  && ok "ENABLE_THINKING=false -> none, with a note" || bad "thinking off: $out"

echo "== 3. a removed setting is gone"
write >/dev/null
[[ "$(get 'c["reasoning_effort"], "--kv" in c["args"], "thinking_budget" in c')" == "('max', False, False)" ]] \
  && ok "back to the defaults" || bad "a setting lingered"

echo "== 4. a bad value"
for probe in REASONING_EFFORT=minimal ENABLE_THINKING=off THINKING_BUDGET=-1 KV=q8 KV=q4_0 KV=k8v4 TEMP=x TOP_P=0 \
             TOP_K=65 MIN_P=2 PRESENCE_PENALTY=-1 REPEAT_PENALTY=0; do
  err="$(env $(clean) "$probe" python3 "$L/maya_settings.py" validate 2>&1)"; r=$?
  [[ $r -eq 2 && "$err" == *"${probe%%=*}"* ]] && ok "$probe refused" || bad "$probe: rc=$r $err"
done
err="$(env $(clean) REASONING_EFFORT=minimal python3 "$L/maya_prepare.py" --tag maya-s --src "$work/nowhere" --data "$work" 2>&1)"; r=$?
[[ $r -ne 0 && "$err" == *REASONING_EFFORT* && "$err" != *"first shard"* ]] \
  && ok "maya_prepare.py stops on it before looking at the shards" || bad "main(): rc=$r $err"

echo "== 5. the pinned engine reads every key a setting writes (engine-config-reads.json; no docker)"
PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/profiles/engine_config_reads.py check --engine strata-maya || rc=1

echo "== 6. exe: the engine the image has (v1.1.16 renamed build/strata to build/maya)"
for case in "maya strata:build/maya" "strata:build/strata" "maya:build/maya" ":build/maya"; do
  have="${case%%:*}" want="${case#*:}" m="$work/opt-maya-${have// /-}"
  mkdir -p "$m/build"; for e in $have; do : > "$m/build/$e"; done
  got="$(python3 - "$L" "$m" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import maya_prepare
maya_prepare.MAYA = Path(sys.argv[2])
print(maya_prepare.engine().relative_to(maya_prepare.MAYA))
PY
)"
  [[ "$got" == "$want" ]] && ok "image with [${have:-none}] -> $got" || bad "image with [${have:-none}]: exe $got, want $want"
done

if [[ "$rc" -eq 0 ]]; then echo "test-maya-config-knobs: ok"; else echo "test-maya-config-knobs: FAILED" >&2; fi
exit "$rc"
