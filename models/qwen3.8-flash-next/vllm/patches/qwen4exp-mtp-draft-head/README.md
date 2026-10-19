# qwen4exp-mtp-draft-head

Gives the Qwen3.8-Flash-Next MTP drafter its own INT4 copy of `lm_head`, so draft steps
stop reading the target's 248,320 x 2,560 BF16 head (about 1.27 GiB per draft step).

**Why.** Stock vLLM shares the target's head with the MTP drafter
(`v1/worker/gpu/spec_decode/eagle/utils.py`, `load_eagle_model`). With MTP n=3 that is
three full-vocabulary BF16 GEMVs per decode step, a large share of a step on a
bandwidth-bound card. The verify pass still uses the target's own head, so the draft
head only changes acceptance, never which tokens are accepted.

**What it does.** With `VLLM_MTP_DRAFT_HEAD_PATH` set:

- `install.sh` builds the file if missing, from `lm_head.weight` of `DRAFT_HEAD_SOURCE`
  (any checkpoint dir with a safetensors index), using `quantize_lm_head.py`: int4,
  group 128, symmetric, GPTQ layout, MSE scale search. About 10 s on the CPU.
- `patch_mtp_draft_head.py` makes `Qwen4ExpMTP` build a W4A16 Marlin `lm_head`, fills it
  from that file instead of the checkpoint, and keeps it instead of adopting the
  target's head. V2 model runner only (the V1 proposer path shares the target head as
  stock does). TP=1 only.

Unset, the patched code behaves exactly like stock.

**Measured** (2x CMP 170HX, PP=2, MTP n=3, 175 W, sparkDash protocol, 2026-10-18):
c=1/c=8 aggregate code 189/668 -> 200/754, json 164/745 -> 186/809, prose
148/514 -> 158/546 tok/s. Acceptance unchanged. KV pool 1.80M -> 1.76M tokens.

**Credit.** Port of AlexBrandes/vllm commit 14457f89e (Apache-2.0) to stock v0.31.0; applies
unchanged to v0.32.0.
`quantize_lm_head.py` is from AlexBrandes/cmp170hx-qwen38-flash-next (MIT), unmodified
apart from its header.

**Re-anchoring.** Four anchors in `models/qwen4_exp/nvidia/mtp.py`, one in
`v1/worker/gpu/spec_decode/eagle/utils.py`. Applies on top of `qwen4exp-mtp-pp` or
without it. Missing or not unique -> the installer exits 1 and the container does not start.
