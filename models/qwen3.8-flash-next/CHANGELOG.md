# Qwen3.8-Flash-Next — Changelog

Dated history for Qwen3.8-Flash-Next configs in this repo. Append-only — add a new entry, don't rewrite past ones.

## 2026-10-18 — first slug on stock vLLM: `vllm/qwen38-flash-next-dual-cmp170hx` (🧪)

Flash-Next on our own `vllm-stable` pin (`vllm/vllm-openai:v0.31.0`), no custom image, for
**2× CMP 170HX 64 GB** (sm_80, the A100's chip). Port 8196. Findings: discussion #1735;
PR #1736.

Layout, chosen by measurement on one rig (Gen2 x8 per card, no P2P, 175 W cap): pipeline
parallel over the two cards with a 26/22 layer split (TP saturates the link: 45/63 vs
117/163 tok/s narr/code), the 51.2 GB FP8 PLE table memory-mapped from NVMe instead of
pinned in RAM (host RAM ~19 GB instead of ~83 GB, decode within 3%), FP8 e4m3 KV (pool
1.99M tokens), MTP n=3 through albucino's compact draft with an INT4 copy of `lm_head`
as the draft head, `--prefix-match-unit 16` and the shared-prefix checkpoint.

Seven new overlays under `models/qwen3.8-flash-next/vllm/patches/` (rows in
`scripts/lib/profiles/patches.yml`, upstream bugs in `docs/UPSTREAM.md`):

- `qwen4exp-pp-ple-rank0` and `qwen4exp-mtp-pp`: stock refuses PP for PLE models and the
  MTP drafter asserts under PP. Ports of Minachist's patches (Apache-2.0).
- `qwen4exp-ple-mmap`: Minachist's mmap PLE, ported to v0.31.0; refuses other versions.
- `qwen4exp-ple-fp8-bytecopy` and `qwen4exp-qsa-fp8kv-ampere`: two `fp8e4nv` compile
  failures on Ampere (pinned-RAM PLE copy, QSA attention reading FP8 KV). The e4m3
  decode is halt95's (Merlin).
- `qwen4exp-mtp-draft-head`: the drafter's own W4A16 `lm_head`, built on first boot
  (port of AlexBrandes/vllm 14457f89e; quantizer MIT). c=8 code 668 -> 754, json
  745 -> 809 tok/s.
- `w4a8-inc-moe`: four vLLM bugs that make W4A8 answer `!!!!` on AutoRound MoE models.
  Opt-in `W4A8=1`; GSM8K 386/400 vs 388/400, decode mixed, so it stays off.

Vision is on, `GPU_MEMORY_UTILIZATION` is 0.95 (pool 2.23M tokens, ~2.7 GB left per
card), and the slug shares the Qwen3.8-27B serving contract: reasoning budget by effort
(`vllm-effort-budget` + `vllm-default-thinking-budget`: low 4,096 / medium 16,384 / xhigh
32,768) and the model card's sampler row chosen by `ENABLE_THINKING`.

Measured 2026-10-18 at 175 W. `report.sh --full` PASS: verify-full incl. vision 4/4,
verify-stress ladder to 240,657 tokens, soak-continuous 0 MiB growth, bench-agentic.
`bench.sh`: 126.1 / 174.0 narr/code, prefill 5,159 @10K / 7,557 @90K, peak 62.8 / 62.2 GB.
sparkDash protocol (greedy, thinking off, 400 forced tokens), aggregate decode
c=1/c=8: code 186/695, prose 163/620, json 192/840 tok/s.

Also: the `vllm-stable` engine lists the `qwen4exp` family; compat allows `fp8_e4m3` KV
for `qwen4exp` on sm_80+ (the overlay above); a `2x-cmp-170hx-64gb` canonical scenario;
`diagnose-profile` picks a card of a slug's `supported_sm`.

Known gaps: `KV_OFFLOAD_GB` does not start under PP=2 (vLLM OffloadingConnector bug);
measured on one rig only.
