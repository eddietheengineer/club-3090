#!/usr/bin/env bash
# qwen4exp-mtp-draft-head installer: runs before `vllm serve`. See patch_mtp_draft_head.py.
# Only acts when VLLM_MTP_DRAFT_HEAD_PATH is set. If that file is missing, it is built
# from the lm_head.weight of DRAFT_HEAD_SOURCE (a checkpoint dir with a safetensors
# index), which takes ~10 s on the CPU, and written next to the path given.
set -u
export PYTHONUTF8="${PYTHONUTF8:-1}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${VLLM_MTP_DRAFT_HEAD_PATH:-}" ] || { echo "[qwen4exp-mtp-draft-head] skipped (VLLM_MTP_DRAFT_HEAD_PATH unset)" >&2; exit 0; }
if [ ! -s "$VLLM_MTP_DRAFT_HEAD_PATH" ]; then
  src="${DRAFT_HEAD_SOURCE:?DRAFT_HEAD_SOURCE must name the checkpoint holding lm_head.weight}"
  echo "[qwen4exp-mtp-draft-head] building $VLLM_MTP_DRAFT_HEAD_PATH from $src/lm_head.weight" >&2
  mkdir -p "$(dirname "$VLLM_MTP_DRAFT_HEAD_PATH")"
  OMP_NUM_THREADS=8 python3 "$here/quantize_lm_head.py" --model-dir "$src" \
    --out "$VLLM_MTP_DRAFT_HEAD_PATH.tmp" --mse-scale-search >/dev/null || exit 1
  mv "$VLLM_MTP_DRAFT_HEAD_PATH.tmp" "$VLLM_MTP_DRAFT_HEAD_PATH"
  mv "$VLLM_MTP_DRAFT_HEAD_PATH.tmp.report.json" "$VLLM_MTP_DRAFT_HEAD_PATH.report.json" 2>/dev/null || true
fi
python3 "$here/patch_mtp_draft_head.py" patch || exit 1
