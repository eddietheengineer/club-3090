#!/usr/bin/env bash
# Guard: the Strata recipe's strata_config.py, which writes club-3090's launch settings into
# Strata's run config at every boot (models/qwen3.8-flash-next/strata/launcher/).
#   1. no settings: the live config is setup's copy, unchanged;
#   2. each setting lands on the key Strata reads (reasoning_effort, reasoning_budget_tokens,
#      sampling.*, --spec in args; never max_tokens); xhigh / max become Strata's "high";
#      ENABLE_THINKING=false wins over REASONING_EFFORT;
#   3. the setup copy is never written, and a setting removed is gone at the next apply;
#   4. needs-setup: only a CONTEXT / KV that differs from what setup was given asks for a new setup
#      (CONTEXT unset means the entrypoint's 131072);
#   5. a bad value exits 2 with the reason, for each setting (the launch-knob catalogue's
#      domain checks run the same `validate`).
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
H="models/qwen3.8-flash-next/strata/launcher/strata_config.py"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# setup's output as Strata v0.1.45 writes it for the ISTA family (secrets left out)
cat > "$work/setup.json" <<'JSON'
{"exe": "/opt/strata/engine/strata",
 "args": ["--pack", "/data/packs/iq3_s", "--prefill", "auto", "--spec", "4", "--spec-min-p", "0.5",
          "--mtp", "/data/mtp/rt", "--max-context", "131072", "--kv", "int8", "--kv-resident", "32768"],
 "model_name": "qwen3.8-flash-next-iq3_s", "port": 8080, "gpu": [0, 1], "host": "0.0.0.0"}
JSON
cp "$work/setup.json" "$work/setup.orig"
SETTINGS="REASONING_EFFORT ENABLE_THINKING THINKING_BUDGET SPEC_N MAX_TOKENS TEMP TOP_P TOP_K MIN_P PRESENCE_PENALTY REPEAT_PENALTY CONTEXT KV"
run() { env $(for v in $SETTINGS; do printf -- '-u %s ' "$v"; done) "$@" python3 "$H" "${CMD[@]}"; }
get() { python3 -c "import json,sys; c=json.load(open('$work/cfg.json')); print(eval(sys.argv[1]))" "$1"; }

echo "== 1. no settings"
CMD=(apply "$work/setup.json" "$work/cfg.json")
out="$(run)" || bad "apply with no settings failed: $out"
cmp -s <(python3 -c "import json;print(json.dumps(json.load(open('$work/setup.json')),sort_keys=True))") \
       <(python3 -c "import json;print(json.dumps(json.load(open('$work/cfg.json')),sort_keys=True))") \
  && ok "live config == setup's copy" || bad "no settings changed the config"
command grep -q "settings: none" <<<"$out" && ok "says it applied none" || bad "summary: $out"

echo "== 2. each setting reaches Strata's key"
out="$(run REASONING_EFFORT=xhigh THINKING_BUDGET=2048 MAX_TOKENS=4096 SPEC_N=3 TEMP=0.6 TOP_P=0.95 TOP_K=20 \
          MIN_P=0 PRESENCE_PENALTY=1.5 REPEAT_PENALTY=1.05)" || bad "apply failed: $out"
[[ "$(get 'c["reasoning_effort"]')" == high ]] && ok "REASONING_EFFORT=xhigh -> reasoning_effort high" || bad "effort: $(get 'c.get("reasoning_effort")')"
[[ "$(get 'c["reasoning_budget_tokens"]')" == 2048 ]] && ok "THINKING_BUDGET -> reasoning_budget_tokens" || bad "budget"
# MAX_TOKENS is not a Strata setting (#1723 wrote it; Strata never read it): nothing may write max_tokens
[[ "$(get '"max_tokens" in c')" == False ]] && ok "MAX_TOKENS ignored (Strata reads no output cap from its config)" \
  || bad "max_tokens written into the config"
[[ "$(get 'c["args"][c["args"].index("--spec")+1]')" == 3 && "$(get 'c["args"].count("--spec")')" == 1 ]] \
  && ok "SPEC_N=3 replaces --spec 4 (once)" || bad "spec: $(get 'c["args"]')"
[[ "$(get 'sorted(c["sampling"].items())')" == "[('min_p', 0.0), ('presence_penalty', 1.5), ('repetition_penalty', 1.05), ('temperature', 0.6), ('top_k', 20), ('top_p', 0.95)]" ]] \
  && ok "sampler settings -> sampling block" || bad "sampling: $(get 'c.get("sampling")')"
out="$(run ENABLE_THINKING=false REASONING_EFFORT=low)" || bad "apply failed: $out"
[[ "$(get 'c["reasoning_effort"]')" == none ]] && command grep -q "ENABLE_THINKING=false wins" <<<"$out" \
  && ok "ENABLE_THINKING=false -> none, and says it overrode REASONING_EFFORT" || bad "thinking off: $out"

echo "== 3. setup's copy is never written; a removed setting is gone"
cmp -s "$work/setup.json" "$work/setup.orig" && ok "setup copy untouched" || bad "apply wrote the setup copy"
run >/dev/null
[[ "$(get '"reasoning_effort" in c or "sampling" in c or c["args"][c["args"].index("--spec")+1] != "4"')" == False ]] \
  && ok "next apply with nothing set: back to setup's config" || bad "a setting lingered"

echo "== 4. needs-setup"
CMD=(needs-setup "$work/setup.json")
run >/dev/null; [[ $? -eq 1 ]] && ok "nothing set: no new setup" || bad "asked for setup with nothing changed"
run CONTEXT=131072 >/dev/null; [[ $? -eq 1 ]] && ok "CONTEXT equal to setup's: no new setup" || bad "CONTEXT equal asked for setup"
out="$(run CONTEXT=65536)" && command grep -q "CONTEXT 131072 -> 65536" <<<"$out" && ok "CONTEXT changed: setup again" || bad "CONTEXT change missed: $out"
out="$(run KV=q4_0)" && command grep -q "KV int8 -> q4_0" <<<"$out" && ok "KV changed: setup again" || bad "KV change missed: $out"
run KV=int8 >/dev/null; [[ $? -eq 1 ]] && ok "KV equal to setup's: no new setup" || bad "KV equal asked for setup"
python3 - "$work/setup.json" "$work/setup65k.json" <<'PY'
import json,sys; c=json.load(open(sys.argv[1])); a=c["args"]; a[a.index("--max-context")+1]="65536"; json.dump(c,open(sys.argv[2],"w"))
PY
CMD=(needs-setup "$work/setup65k.json")
out="$(run)" && command grep -q "CONTEXT 65536 -> 131072" <<<"$out" && ok "CONTEXT unset after a 65536 setup: back to 131072" || bad "unset CONTEXT kept 65536: $out"

echo "== 5. a bad value exits 2 with the reason"
CMD=(validate)
for probe in REASONING_EFFORT=minimal ENABLE_THINKING=off THINKING_BUDGET=-1 SPEC_N=0 SPEC_N=9 \
             TEMP=x TOP_P=0 TOP_K=65 MIN_P=2 PRESENCE_PENALTY=-1 REPEAT_PENALTY=0 KV=q8 CONTEXT=100; do
  err="$(run "$probe" 2>&1)"; r=$?
  [[ $r -eq 2 && "$err" == *"${probe%%=*}"* ]] && ok "$probe refused" || bad "$probe: rc=$r $err"
done
run REASONING_EFFORT=max SPEC_N=8 KV=k8v4 CONTEXT=262144 >/dev/null && ok "valid values pass" || bad "valid values refused"

if [[ "$rc" -eq 0 ]]; then echo "test-strata-config-knobs: ok"; else echo "test-strata-config-knobs: FAILED" >&2; fi
exit "$rc"
