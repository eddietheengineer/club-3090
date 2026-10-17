#!/usr/bin/env bash
# test-cpu-offload-gb-fit — guards `resolve_cpu_offload_gb` (bucko on 32 GB cards, #1700).
#
# REDs on: a 24 GB rig getting anything but the compose default · a 32 GB rig NOT
# getting the measured point (the #1700 defect: 2x 5090 ran the 24 GB value and left
# ~7.5 GiB per card idle) · a value past the measured points (the sizer must never
# extrapolate) · one small or busy card not holding the whole rig back · a value the
# user set being clobbered, or a too-low one going unwarned · the resolver firing on
# a compose that never asked for it · switch.sh calling it after the RAM gate or
# not at all · a header whose points don't sit below its compose's own default.
#
# The numbers are MEASURED, not derived (bucko upstream issue #7, @paulp83): if the
# compose header's point changes, change the anchors here with it.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

FAIL=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1" >&2; FAIL=1; }

PLE="models/qwen3.8-flash-next/bucko-vllm/compose/dual/albucino-autoround-int4-fp8ple/base.yml"

# CPU_OFFLOAD_GB_FREE_MIB is the test seam, so the decision reproduces without a GPU.
# Every call runs under `set -euo pipefail`, as switch.sh does: a resolver that
# returns non-zero there aborts the launcher mid-boot.
value_for() { # value_for <compose> <free-list> [user value]
  CPU_OFFLOAD_GB_FREE_MIB="$2" CPU_OFFLOAD_GB="${3:-}" bash -c '
    set -euo pipefail
    source scripts/lib/compose-meta.sh
    [[ -n "${CPU_OFFLOAD_GB:-}" ]] || unset CPU_OFFLOAD_GB
    resolve_cpu_offload_gb "$1" >/dev/null 2>&1
    printf "%s" "${CPU_OFFLOAD_GB:-unset}"' _ "$1" || printf 'rc-fail'
}
says_for() { # says_for <compose> <free-list> [user value]  → the resolver's stderr
  CPU_OFFLOAD_GB_FREE_MIB="$2" CPU_OFFLOAD_GB="${3:-}" bash -c '
    set -euo pipefail
    source scripts/lib/compose-meta.sh
    [[ -n "${CPU_OFFLOAD_GB:-}" ]] || unset CPU_OFFLOAD_GB
    resolve_cpu_offload_gb "$1" 2>&1 >/dev/null' _ "$1"
}

echo "== resolve_cpu_offload_gb"

# --- 1. the reference rig: 2x 3090, 24,123 MiB free per card --------------------
got="$(value_for "$PLE" "24123 24123")"
[[ "$got" == "unset" ]] && ok "2x 24 GB keeps the compose default (nothing exported)" \
                        || bad "2x 24 GB: want the compose default, got CPU_OFFLOAD_GB=${got}"
out="$(says_for "$PLE" "24123 24123")"
[[ "$out" == *"CPU_OFFLOAD_GB=30 (compose default)"*"24123"* ]] \
  && ok "the no-op still prints its decision and the free VRAM it read" \
  || bad "the no-op is silent or unexplained: '${out}'"

# --- 2. POSITIVE CONTROL: the 32 GB class gets the measured point ---------------
# An idle headless 5090 shows ~32,1xx MiB free. If this one fails, the sizer would
# not fire on the very rig that measured 22 (#1700).
got="$(value_for "$PLE" "32150 32150")"
[[ "$got" == "22" ]] && ok "2x 32 GB gets the measured 22" \
                     || bad "2x 32 GB: want 22, got ${got} — the #1700 defect is back"
got="$(value_for "$PLE" "31130 31130")"
[[ "$got" == "22" ]] && ok "exactly the requirement (31130 MiB) qualifies" \
                     || bad "boundary: 31130 free should qualify, got ${got}"
got="$(value_for "$PLE" "31129 31129")"
[[ "$got" == "unset" ]] && ok "one MiB under the requirement does not" \
                        || bad "boundary: 31129 free must not qualify, got ${got}"

# --- 3. the smallest card decides ----------------------------------------------
# CPU_OFFLOAD_GB is one value for every worker, so one 24 GB card or one busy card
# holds the whole rig at the default.
got="$(value_for "$PLE" "24123 32150")"
[[ "$got" == "unset" ]] && ok "a 24 GB + 32 GB rig stays at the default" \
                        || bad "mixed cards: want the default, got ${got}"
got="$(value_for "$PLE" "32150 30000")"
[[ "$got" == "unset" ]] && ok "a 32 GB card with ~2 GB in use elsewhere stays at the default" \
                        || bad "busy card: want the default, got ${got}"

# --- 4. no extrapolation -------------------------------------------------------
got="$(value_for "$PLE" "48000 48000")"
[[ "$got" == "22" ]] && ok "a 48 GB card gets the lowest MEASURED value (22), not a guess" \
                     || bad "48 GB: want 22 (no extrapolation), got ${got}"

# --- 5. a value the user set always wins --------------------------------------
got="$(value_for "$PLE" "32150 32150" 28)"
[[ "$got" == "28" ]] && ok "CPU_OFFLOAD_GB=28 is kept on a 32 GB rig" \
                     || bad "user value clobbered: want 28, got ${got}"
out="$(says_for "$PLE" "32150 32150" 28)"
[[ "$out" == *"YOUR value, kept"*"would pick 22"* ]] \
  && ok "a user value still reports what the sizer would have picked" \
  || bad "a user value hid the sizer's choice: '${out}'"
[[ "$out" != *"⚠️"* ]] && ok "28 on a 32 GB rig is not warned (it keeps more in host RAM than 22)" \
                       || bad "28 on a 32 GB rig was warned: '${out}'"
out="$(says_for "$PLE" "24123 24123" 22)"
[[ "$out" == *"Expect an out-of-memory"* ]] \
  && ok "22 on a 24 GB rig warns: the measured point needs 31130 MiB" \
  || bad "22 on a 24 GB rig went unwarned: '${out}'"
out="$(says_for "$PLE" "32150 32150" 18)"
[[ "$out" == *"nothing measured says 18 fits"* ]] \
  && ok "18 (below every measured value) is labelled unmeasured" \
  || bad "a value past the measured points went unflagged: '${out}'"
out="$(says_for "$PLE" "32150 32150" 22)"
[[ "$out" != *"⚠️"* ]] && ok "the measured value on the measured class is not warned" \
                       || bad "22 on a 32 GB rig was warned: '${out}'"

# --- 6. no-op everywhere else --------------------------------------------------
other="models/qwen3.8-flash-next/bucko-vllm/compose/dual/ukisai-swift15-autoround-int4/base.yml"
if [[ -f "$other" ]]; then
  got="$(value_for "$other" "32150 32150")"
  out="$(says_for "$other" "32150 32150")"
  [[ "$got" == "unset" && -z "$out" ]] \
    && ok "silent no-op on the Swift-1.5 compose (no measured point yet)" \
    || bad "the sizer fired on a compose without the header: CPU_OFFLOAD_GB=${got} '${out}'"
else
  bad "fixture missing: ${other}"
fi
got="$(PATH=/nonexistent "$BASH" -c '
  set -euo pipefail
  source scripts/lib/compose-meta.sh
  unset CPU_OFFLOAD_GB CPU_OFFLOAD_GB_FREE_MIB
  resolve_cpu_offload_gb "$1" >/dev/null 2>&1
  printf "%s" "${CPU_OFFLOAD_GB:-unset}"' _ "$PLE" 2>/dev/null || printf 'rc-fail')"
[[ "$got" == "unset" ]] && ok "no nvidia-smi: no-op, and no failure under set -e" \
                        || bad "without nvidia-smi the sizer gave '${got}'"

# --- 7. every header is coherent with its own compose -------------------------
# Each measured value must sit below the compose's own ${CPU_OFFLOAD_GB:-N}; the
# sizer reads N from the compose, and a point at or above it would never apply.
n_headers=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  n_headers=$((n_headers + 1))
  text="$(cat "$f")"
  if [[ "$text" =~ CPU_OFFLOAD_GB:-([0-9]+) ]]; then
    def="${BASH_REMATCH[1]}"
  else
    bad "${f}: declares CPU-Offload-GB-Measured but has no \${CPU_OFFLOAD_GB:-N} default"
    continue
  fi
  pts="$(bash -c 'source scripts/lib/compose-meta.sh; compose_meta_get "$1" cpu-offload-gb-measured' _ "$f")"
  good=1
  for p in $pts; do
    if [[ ! "$p" =~ ^([0-9]+)@([0-9]+)$ ]] || (( BASH_REMATCH[1] >= def )); then good=0; fi
  done
  (( good == 1 )) && ok "$(dirname "${f#models/}"): points '${pts}' parse and sit below its default ${def}" \
                  || bad "${f}: bad CPU-Offload-GB-Measured '${pts}' (format <value>@<MiB>, value < ${def})"
done < <(command grep -rlE '^#[[:space:]]*CPU-Offload-GB-Measured:' models --include='*.yml' 2>/dev/null)
(( n_headers >= 1 )) && ok "${n_headers} compose(s) declare a measured point" \
                     || bad "no compose declares CPU-Offload-GB-Measured — the scan is broken or the header was dropped"

# --- 8. switch.sh calls it, before the RAM gate and before compose up ----------
body="$(sed -n '/^up_variant()/,/^}/p' scripts/switch.sh)"
call="$(printf '%s\n' "$body" | command grep -nE '^[[:space:]]*resolve_cpu_offload_gb[[:space:]]' | head -1 | cut -d: -f1)"
gate="$(printf '%s\n' "$body" | command grep -nE '^[[:space:]]*preflight_cpu_offload_ram[[:space:]]' | head -1 | cut -d: -f1)"
up="$(printf '%s\n' "$body" | command grep -n 'bringing up' | head -1 | cut -d: -f1)"
if [[ -n "$call" && -n "$gate" && -n "$up" ]] && (( call < gate && call < up )); then
  ok "switch.sh up_variant resolves it before the host-RAM gate and before compose up"
else
  bad "switch.sh wiring: resolve_cpu_offload_gb line '${call}', RAM gate '${gate}', up '${up}'"
fi

echo
if (( FAIL )); then echo "FAIL"; exit 1; fi
echo "PASS"
