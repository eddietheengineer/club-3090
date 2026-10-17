#!/usr/bin/env bash
# test-compose-gpu-mask-passthrough.sh — every compose that selects GPUs via
# the NVIDIA_VISIBLE_DEVICES env line MUST also pass CUDA_VISIBLE_DEVICES
# through (#610): CDI runtimes (NixOS, nvidia-ctk cdi) ignore
# NVIDIA_VISIBLE_DEVICES entirely, so the CUDA-level mask is the only thing
# that pins cards there. launch.sh --gpus exports both as GPU UUIDs
# (renumbering-proof on the classic runtime too). A new compose that copies
# the NVIDIA line but forgets the CUDA passthrough silently regresses CDI
# rigs — this guard reds instead.
#
# Composes that pick cards with device_ids instead (#1695) must fall back through
# CUDA_VISIBLE_DEVICES: `device_ids: ['${ESTATE_GPUS:-${CUDA_VISIBLE_DEVICES:-0,1}}']`.
# launch.sh --gpus reaches them only that way (it exports the UUIDs; docker takes UUIDs as
# device IDs). A fixed default (['${ESTATE_GPUS:-0,1}']) ignored --gpus: on a 4-card rig
# `--gpus 0,3` ran Strata on GPUs 0 and 1, and --gpus 1 put a single-card slug on GPU 0.
# The device_ids form (not the NVIDIA env line above) is what these engines need: the
# container sees only the chosen cards, so engines that number GPUs as nvidia-smi does
# (Strata) and llama.cpp layer splits over every visible card both get the right set.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
while IFS= read -r f; do
  # bare passthrough form: "- CUDA_VISIBLE_DEVICES" (no =value; unset → absent)
  if ! grep -Eq '^\s*- CUDA_VISIBLE_DEVICES\s*$' "$f"; then
    echo "FAIL: $f sets NVIDIA_VISIBLE_DEVICES but does not pass CUDA_VISIBLE_DEVICES through (#610 CDI regression)" >&2
    fails=$((fails+1))
  fi
done < <(grep -rlE '^\s*- NVIDIA_VISIBLE_DEVICES=' models/*/*/compose --include='*.yml' 2>/dev/null | grep -v '/_archive/' || true)

# device_ids composes (#1695): every device_ids line must fall back through CUDA_VISIBLE_DEVICES.
n_dev=0
while IFS= read -r hit; do
  n_dev=$((n_dev+1))
  case "$hit" in
    *CUDA_VISIBLE_DEVICES*) : ;;
    *) rest="${hit#*:}"
       echo "FAIL: ${hit%%:*}:${rest%%:*} picks cards with device_ids but ignores launch.sh --gpus; use ['\${ESTATE_GPUS:-\${CUDA_VISIBLE_DEVICES:-<default>}}'] (#1695):${rest#*:}" >&2
       fails=$((fails+1)) ;;
  esac
done < <(command grep -rnE '^\s*device_ids:' models/*/*/compose --include='*.yml' 2>/dev/null | command grep -v '/_archive/' || true)
[[ $n_dev -gt 0 ]] || { echo "FAIL: found no device_ids composes at all (the search is broken, not the tree)" >&2; fails=$((fails+1)); }

# The UUID resolution (other half of #610) moved into the shared
# scripts/lib/gpu-select.sh lib (Phase A); launch.sh must source + use it.
# (test-gpu-select asserts the lib itself + bash/python resolver parity.)
grep -q 'query-gpu=uuid' scripts/lib/gpu-select.sh \
  || { echo "FAIL: gpu-select.sh lost the index→UUID resolution (#610)" >&2; fails=$((fails+1)); }
grep -q 'scripts/lib/gpu-select.sh' scripts/launch.sh \
  || { echo "FAIL: launch.sh no longer sources gpu-select.sh (#610)" >&2; fails=$((fails+1)); }

if [[ $fails -gt 0 ]]; then
  echo "$fails GPU-mask passthrough check(s) failed" >&2
  exit 1
fi
echo "PASS: all NVIDIA_VISIBLE_DEVICES composes pass CUDA_VISIBLE_DEVICES through; all ${n_dev} device_ids composes fall back through it; launch.sh UUID resolution present"
