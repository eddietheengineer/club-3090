#!/usr/bin/env bash
# w4a8-inc-moe installer: runs before `vllm serve`, after w4a8-int8-act.
# No-op unless VLLM_MARLIN_INPUT_DTYPE=int8. See patch_w4a8_inc_moe.py.
set -u
export PYTHONUTF8="${PYTHONUTF8:-1}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ "${VLLM_MARLIN_INPUT_DTYPE:-}" = "int8" ] || exit 0
python3 "$here/patch_w4a8_inc_moe.py" patch || exit 1
