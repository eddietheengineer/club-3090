#!/usr/bin/env bash
# Guard: the MiniMax-M3.1-Flash Project Maya recipe (models/minimax-m3.1-flash/strata-maya/launcher/) writes
# club-3090's launch settings into maya-mm3.json at every boot (mm3_prepare.py config() through mm3_settings.py),
# and prepares the pack the way the slugs need. Runs the launcher's own functions against scratch folders (no
# /opt/maya, no weights):
#   1. no settings: effort auto, sampling 1.0 / 0.95, name minimax-m3.1-flash, maya-mm3 with the shipped expert
#      profile, K / V streaming on, --vision off, --dspark on and a --cpu-threads from threads(); no --kv-cache; the
#      installer record Maya's model_label reads (mm3_quant gguf-s: "MiniMax M3.1 · Maya-S");
#   2. each setting lands on Maya's key; MiniMax's five levels stay as they are (medium / xhigh are its own, not
#      folded into high / max as for GLM); ENABLE_THINKING=false wins; KV, DSPARK and THREADS set their flags;
#      LOOP_GUARD writes loop_guard; SPEC_N / MAX_TOKENS write nothing;
#   3. the config is rewritten from scratch each time, so a setting removed is gone;
#   4. a bad value exits 2 from `validate` and stops mm3_prepare.py's main() before it looks at any file; KV fp8 / fp4
#      are refused with the reason; missing weights stop the boot naming the files and the download;
#   5. threads(): half the CPUs (nproc / 2), at least 1;
#   6. pack(): pack_gguf.py gets --companions and all four .gguf names (the indexers side file among them), and a
#      repack keeps the engine's prefill calibration (prefill-tune.txt);
#   7. verify(): a file whose SHA-256 is wrong stops the boot; a matching set is recorded and not hashed again;
#   8. every key a setting writes has evidence that the pinned Maya reads it (engine_config_reads.py check).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1   # the launcher folder is mounted into the container: leave no __pycache__
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
L="models/minimax-m3.1-flash/strata-maya/launcher"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
SETTINGS="REASONING_EFFORT ENABLE_THINKING THINKING_BUDGET MAX_TOKENS KV SPEC_N TEMP TOP_P TOP_K MIN_P PRESENCE_PENALTY REPEAT_PENALTY SERVED_NAME THREADS LOOP_GUARD DSPARK"
clean() { for v in $SETTINGS; do printf -- '-u %s ' "$v"; done; }
# config() for minimax-maya-s into $work/minimax-maya-s/maya-mm3.json, with the given settings
write() {
  env $(clean) "$@" python3 - "$L" "$work" <<'PY'
import sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mm3_prepare
d = Path(sys.argv[2]) / "minimax-maya-s"; d.mkdir(exist_ok=True)
mm3_prepare.config("minimax-maya-s", d, d / "pack", types.SimpleNamespace(gpus="0,1", context=65536))
PY
}
get() { python3 -c "import json,sys; c=json.load(open('$work/minimax-maya-s/maya-mm3.json')); a=c['args']; print(eval(sys.argv[1]))" "$1"; }
arg() { get "a[a.index('$1')+1] if '$1' in a else None"; }

echo "== 1. no settings"
write >/dev/null || bad "config() failed with no settings"
[[ "$(get 'c["reasoning_effort"]')" == auto ]] && ok "effort auto (Maya's own for MiniMax: its adaptive thinking)" || bad "effort: $(get 'c.get("reasoning_effort")')"
[[ "$(get 'c["sampling"]')" == "{'temperature': 1.0, 'top_p': 0.95}" ]] && ok "sampling 1.0 / 0.95 (the model card's)" || bad "sampling: $(get 'c["sampling"]')"
[[ "$(get 'c["model_name"]')" == minimax-m3.1-flash ]] && ok "served as minimax-m3.1-flash" || bad "model_name: $(get 'c.get("model_name")')"
[[ "$(get 'c["exe"]')" == /opt/maya/build/maya-mm3 ]] && ok "exe maya-mm3" || bad "exe: $(get 'c["exe"]')"
# (Maya's model_label reads mm3_quant: without it, the files are named "EXL3 3.5 bpw" - Maya's EXL3 quant)
[[ "$(get 'c["installer"]["family"], c["installer"]["mm3_quant"]')" == "('minimax', 'gguf-s')" ]] \
  && ok "installer record: family minimax, mm3_quant gguf-s (Maya-S)" || bad "installer: $(get 'c["installer"]')"
[[ "$(arg --profile) $(arg --kv-streaming) $(arg --vision) $(arg --dspark) $(arg --max-context)" == "/opt/maya/data/expert-profile-mm3.bin on off on 65536" ]] \
  && ok "the shipped expert profile, K / V streaming on, --vision off, --dspark on, --max-context 65536" || bad "args: $(get 'a')"
want="$(env $(clean) python3 -c "import sys; sys.path.insert(0, '$L'); import mm3_settings; print(mm3_settings.threads())")"
[[ "$(arg --cpu-threads)" == "$want" && "$want" -ge 1 ]] && ok "--cpu-threads $want = threads()" || bad "--cpu-threads $(arg --cpu-threads), threads() $want"
[[ "$(get '"thinking_budget" in c or "loop_guard" in c or "--kv-cache" in a or "--tp" in a')" == False ]] \
  && ok "no thinking_budget / loop_guard / --kv-cache / --tp: Maya's own (a GGUF pack runs as a layer split)" || bad "an unset setting was written: $(get 'a')"
[[ "$(get 'c["gpu"]') $(get 'c["log"].endswith("/minimax-maya-s/maya-mm3.log")') $(get 'c["tokenizer"].endswith("/pack/tokenizer")')" == "[0, 1] True True" ]] \
  && ok "GPUs [0, 1], the engine log in the quant's folder, the pack's tokenizer" || bad "gpu/log/tokenizer: $(get 'c["gpu"], c["log"], c["tokenizer"]')"

echo "== 2. each setting reaches Maya's key"
write REASONING_EFFORT=medium THINKING_BUDGET=8192 TEMP=0.7 TOP_P=0.9 TOP_K=40 MIN_P=0.05 PRESENCE_PENALTY=0.5 \
      REPEAT_PENALTY=1.1 THREADS=7 KV=bf16 DSPARK=off SPEC_N=3 MAX_TOKENS=4096 >/dev/null || bad "config() failed"
[[ "$(get 'c["reasoning_effort"]')" == medium ]] && ok "medium stays medium (MiniMax's own level)" || bad "effort: $(get 'c["reasoning_effort"]')"
[[ "$(get 'c["thinking_budget"]')" == 8192 ]] && ok "thinking_budget" || bad "budget: $(get 'c.get("thinking_budget")')"
[[ "$(arg --cpu-threads) $(arg --kv-cache) $(arg --dspark)" == "7 bf16 off" ]] && ok "THREADS=7, KV=bf16, DSPARK=off -> --cpu-threads 7 --kv-cache bf16 --dspark off" \
  || bad "args: $(get 'a')"
[[ "$(get 'a.count("--dspark")')" == 1 ]] && ok "one --dspark (the setting replaces the default)" || bad "--dspark twice: $(get 'a')"
[[ "$(get '"--spec" in a or "max_tokens" in c')" == False ]] \
  && ok "SPEC_N / MAX_TOKENS write nothing (maya-mm3 has no depth flag)" || bad "SPEC_N/MAX_TOKENS written: $(get 'a')"
[[ "$(get 'sorted(c["sampling"].items())')" == "[('min_p', 0.05), ('presence_penalty', 0.5), ('repetition_penalty', 1.1), ('temperature', 0.7), ('top_k', 40), ('top_p', 0.9)]" ]] \
  && ok "sampler settings" || bad "sampling: $(get 'c["sampling"]')"
for e in auto low high xhigh max none; do
  write REASONING_EFFORT=$e >/dev/null; [[ "$(get 'c["reasoning_effort"]')" == "$e" ]] || bad "REASONING_EFFORT=$e -> $(get 'c["reasoning_effort"]')"
done; ok "auto / low / high / xhigh / max / none reach the config as they are"
write SERVED_NAME=llm >/dev/null; [[ "$(get 'c["model_name"]')" == llm ]] && ok "SERVED_NAME=llm -> model_name llm" || bad "served name: $(get 'c["model_name"]')"
write LOOP_GUARD=false >/dev/null; [[ "$(get 'c["loop_guard"]')" == False ]] && ok "LOOP_GUARD=false -> loop_guard false" || bad "loop guard off: $(get 'c.get("loop_guard")')"
write LOOP_GUARD=true >/dev/null; [[ "$(get 'c["loop_guard"]')" == True ]] && ok "LOOP_GUARD=true -> loop_guard true" || bad "loop guard on: $(get 'c.get("loop_guard")')"
write KV=int8 >/dev/null; [[ "$(arg --kv-cache)" == int8 ]] && ok "KV=int8 -> --kv-cache int8" || bad "kv int8: $(get 'a')"
out="$(write ENABLE_THINKING=false REASONING_EFFORT=high)"
[[ "$(get 'c["reasoning_effort"]')" == none ]] && command grep -q "ENABLE_THINKING=false wins" <<<"$out" \
  && ok "ENABLE_THINKING=false -> none, with a note" || bad "thinking off: $out"

echo "== 3. a removed setting is gone"
write >/dev/null
[[ "$(get 'c["reasoning_effort"], "thinking_budget" in c, c["model_name"], a[a.index("--cpu-threads")+1], "loop_guard" in c, "--kv-cache" in a, a[a.index("--dspark")+1]')" == "('auto', False, 'minimax-m3.1-flash', '$want', False, False, 'on')" ]] \
  && ok "back to the defaults" || bad "a setting lingered: $(get 'c["reasoning_effort"], "thinking_budget" in c, c["model_name"], a')"

echo "== 4. a bad value"
for probe in REASONING_EFFORT=minimal REASONING_EFFORT=75 REASONING_EFFORT=HIGH ENABLE_THINKING=off THINKING_BUDGET=-1 \
             TEMP=x TOP_P=0 TOP_K=65 MIN_P=2 PRESENCE_PENALTY=-1 REPEAT_PENALTY=0 THREADS=0 THREADS=four \
             LOOP_GUARD=off LOOP_GUARD=0 KV=q8_0 DSPARK=1 DSPARK=true; do
  err="$(env $(clean) "$probe" python3 "$L/mm3_settings.py" validate 2>&1)"; r=$?
  [[ $r -eq 2 && "$err" == *"${probe%%=*}"* ]] && ok "$probe refused" || bad "$probe: rc=$r $err"
done
err="$(env $(clean) KV=fp8 python3 "$L/mm3_settings.py" validate 2>&1)"; r=$?
[[ $r -eq 2 && "$err" == *"isn't validated"* ]] && ok "KV=fp8 refused, saying why" || bad "KV=fp8: rc=$r $err"
err="$(env $(clean) KV=fp4 python3 "$L/mm3_settings.py" validate 2>&1)"; r=$?
[[ $r -eq 2 && "$err" == *"KV floor"* ]] && ok "KV=fp4 refused, saying why" || bad "KV=fp4: rc=$r $err"
err="$(env $(clean) "SERVED_NAME=my model" python3 "$L/mm3_settings.py" validate 2>&1)"; r=$?
[[ $r -eq 2 && "$err" == *SERVED_NAME* ]] && ok "SERVED_NAME with a space refused" || bad "SERVED_NAME=my model: rc=$r $err"
err="$(env $(clean) REASONING_EFFORT=minimal python3 "$L/mm3_prepare.py" --tag minimax-maya-s --src "$work/nowhere" \
       --companions "$work/nowhere" --data "$work" 2>&1)"; r=$?
[[ $r -ne 0 && "$err" == *REASONING_EFFORT* && "$err" != *missing* ]] \
  && ok "mm3_prepare.py stops on it before looking at the files" || bad "main(): rc=$r $err"
err="$(env $(clean) python3 "$L/mm3_prepare.py" --tag minimax-maya-s --src "$work/nowhere" --companions "$work/nowhere" \
       --data "$work" 2>&1)"; r=$?
[[ $r -ne 0 && "$err" == *missing:* && "$err" == *maya-indexers.gguf* && "$err" == *dspark/model-dspark* && "$err" == *setup.sh* ]] \
  && ok "missing weights: stops, names the shards, the indexers file, the drafter and the download" || bad "missing weights: rc=$r $err"

echo "== 5. threads(): half the CPUs (nproc / 2), at least 1"
out="$(python3 -c "import sys; sys.path.insert(0, '$L'); import mm3_settings as s; print(s.threads(list(range(32))), s.threads([0]), s.threads([]))")"
[[ "$out" == "16 1 1" ]] && ok "32 CPUs -> 16, 1 -> 1, none -> 1" || bad "threads(): $out"

echo "== 6. pack(): --companions, every .gguf name, and a repack keeps the prefill calibration"
out="$(python3 - "$L" "$work" <<'PY' 2>&1
import sys, types
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mm3_prepare as p
w = Path(sys.argv[2]) / "pk"; (w / "gguf").mkdir(parents=True); (w / "comp" / "dspark").mkdir(parents=True)
model = [w / "gguf" / n for n in p.WEIGHTS["minimax-maya-s"]["gguf"]]
drafter = [w / "comp" / "dspark" / n for n in p.WEIGHTS["minimax-maya-s"]["dspark"]]
for f in model + drafter:
    f.write_bytes(b"x")
seen = []
def fake_run(cmd, cwd=None):
    seen.append(cmd)
    out = Path(cmd[cmd.index("--out") + 1]); out.mkdir(parents=True, exist_ok=True)
    (out / "tensors.txt").write_text("t\n")
    return types.SimpleNamespace(returncode=0)
p.subprocess.run = fake_run
d = w / "data"; d.mkdir()
pk = p.pack(model, drafter, w / "comp", d, False)
cmd = seen[-1]
print("companions", cmd[cmd.index("--companions") + 1] == str(w / "comp"))
print("shards", cmd[cmd.index("--shards") + 1:] == [f.name for f in model])
(pk / "prefill-tune.txt").write_text("chunk 2048\n")
p.pack(model, drafter, w / "comp", d, False)
print("rebuilt-when-unchanged", len(seen) > 1)
p.pack(model, drafter, w / "comp", d, True)
print("kept", (pk / "prefill-tune.txt").read_text() == "chunk 2048\n")
PY
)"
[[ "$out" == *"companions True"* && "$out" == *"shards True"* ]] \
  && ok "pack_gguf.py gets --companions and all four .gguf names (the indexers file among them)" || bad "pack command: $out"
[[ "$out" == *"rebuilt-when-unchanged False"* ]] && ok "an up-to-date pack isn't built again" || bad "pack rebuilt: $out"
[[ "$out" == *"kept True"* ]] && ok "REPACK keeps prefill-tune.txt" || bad "prefill-tune.txt lost: $out"

echo "== 7. verify(): the SHA-256 table stops a damaged file; a match is recorded"
out="$(python3 - "$L" "$work" <<'PY' 2>&1
import hashlib, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import mm3_prepare as p
w = Path(sys.argv[2]) / "v"; w.mkdir()
f = w / "a.gguf"; f.write_bytes(b"good")
p.WEIGHTS["t"] = {"gguf": {"a.gguf": hashlib.sha256(b"good").hexdigest()}, "dspark": {}}
p.verify("t", [f], w)                               # matches: recorded
calls = []
p.sha256 = lambda x: calls.append(x) or "never"     # a second verify must not hash again
p.verify("t", [f], w)
print("rehashed" if calls else "not rehashed")
f.write_bytes(b"bad!")                               # same size, different bytes ...
st = f.stat()                                        # ... and a later mtime, set: two writes inside one tick of
os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns + 10**9))  # the kernel's file clock share one (2.3% of runs, 2026-10-29)
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
PYTHONDONTWRITEBYTECODE=1 python3 scripts/lib/profiles/engine_config_reads.py check --engine strata-maya:mm3 || rc=1

if [[ "$rc" -eq 0 ]]; then echo "test-maya-mm3-config: ok"; else echo "test-maya-mm3-config: FAILED" >&2; fi
exit "$rc"
