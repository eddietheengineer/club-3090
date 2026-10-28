# Qwen3.8-Flash-Next — Changelog

Dated history for Qwen3.8-Flash-Next configs in this repo. Append-only — add a new entry, don't rewrite past ones.

## 2026-10-28 — second flash-half defect: 8-slot VRAM OOM → ship FLASH_MAX_SEQS=4

With `FLASH_COMM=ce` in place, the 8-pack still killed the engine — a *different* fault:
`[flash] graph instantiate out of memory` then `CUDA error cudaErrorMemoryAllocation at
gemm.cu:3456` → abort. The QE-INT4 weights + 51.8 GB pinned n-gram table leave only ~0.25 GiB
free per card at 8 sequence slots, and the 8-pack's concurrent multi-turn load (hermesagent-20,
136K-token prompts) exhausts it — a headroom failure, not the NaN. `FLASH_MAX_SEQS=4` passes the
full 8-pack (117/150 thinking-OFF, restarts=0), so the compose now ships 4 as the default
(overridable). Both flash-half defects reproduce identically on 1.3-rc4, so neither is a bump
regression.

## 2026-10-28 — long-prefill NaN found; the slug ships FLASH_COMM=ce

Re-validating this slug on the 1.3 pin, `bench.sh`'s 90K-prefill step killed the engine:
`[flash] GUARD: non-finite lm_head input in prefill at position 76418`, then
`FATAL: 5 non-finite faults within 5 minutes … shared state is likely corrupt; exiting`.
Reproduced deterministically with a single ~76K-token prefill on a fresh boot (no archive
history involved). **The A/B exonerates the pin bump:** 1.3-rc4 faults at the same position
with the same block count — and dies *faster* (rc4 exits on the first fault; 1.3 tolerates 4
per 5 min). The trigger is the engine's `FLASH_COMM=auto` probe picking the **P2P SM
load/store** path on this PCIe rig; `FLASH_COMM=ce` (copy-engine transfers) measured clean
across 4×76K prefills, so the compose now ships `ce` as the default (overridable). The
earlier rc4-era "verify-full 9/9" stays consistent — that suite has no 76K prefill.
Upstream: no known issue as of 2026-10-28.

## 2026-10-28 — QEngine pin bump: 1.3-rc4 → 1.3 (shared image)

The QEngine image pin moved to the final `1.3` (`sha256:b9d1b0af…`, source `d15a4d3a` = git tag
`v1.3`). 1.3 is a functional delta from rc4 (per-GPU engine process + GPU lock; the host-RAM
archive is now capped at `MemAvailable` minus a margin and returned under pressure — relevant
here, where the archive is already lowered to 16 GB for the pinned n-gram table; over-ctx
prompts now get HTTP 400; `src/flash/*` heavily rewritten). **Contract-checked on the image,
not live-booted at bump time:** the entrypoint, every `FLASH_*`/`QE_*` knob this compose sets,
and `--think`/`--mtp-k`/`--max-ctx`/`--served-name` are all present on `1.3`. The 2026-10-27
verify-full / output-clean numbers are rc4-measured — re-boot and re-run `verify-full` on `1.3`
before trusting them. Pin row: `docs/UPSTREAM.md`.

## 2026-10-28 — QEngine Flash-Next slug ships 131K context

`qengine/qwen38-flash-next-dual` now ships **131,072** context (was 262,144): the compose's
`--max-ctx` default and the registry `max_ctx` lowered together. The engine still accepts
`MAX_MODEL_LEN=` up to its 262K ceiling; the shipped default is the half-size window.

## 2026-10-27 — QEngine Flash-Next preview slug (🐣)

**`qengine/qwen38-flash-next-dual`** (port 8146) runs the same pinned QEngine image's
second engine (`libqflash.so`) on bpx03's QE-INT4 conversion
(`bpx03/Qwen3.8-Flash-Next-QEngine`, 128 GB: W4A16 + INT8 n-gram table + MTP head — a
weight format that loads in no other engine here). TP=2 on two 3090s: verify-full 9/9
(MTP accept-len 3.97), clean en/ja/fr output — the same artifact garbled on the 1.3-rc1/rc2
images (2026-10-26), so the rc4 pin is load-bearing. ⚠️ The 51.8 GB INT8 n-gram table is
pinned in host RAM (~80 GB total with the archive lowered to 16 GB); `FLASH_NGRAM_PIN=0`
switches to disk mode. Upstream tests this half on 3 cards only. 🐣 Incubating; bench /
stress / soak / 8-pack pending.

## 2026-10-18 — first slug on stock vLLM: `vllm/qwen38-flash-next-dual` (🧪)

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

## 2026-10-18 — `vllm/qwen38-flash-next-dual` moves to vLLM v0.32.0

The slug follows `vllm-stable` to the stock `vllm/vllm-openai:v0.32.0` (#1740).

Overlays:

- `qwen4exp-ple-mmap`: re-ported to v0.32.0 (`ple-mmap-v0.32.0.diff`). Upstream's PLE
  prefetch interface changed (`start_prefetch(ngram_ids)`, `finalize_prefetch(total_tokens)`,
  a `reduce_results` argument).
- `qwen4exp-qsa-fp8kv-ampere`: also turns off v0.32.0's fused QSA prepare (vllm#57097) for
  FP8 KV below sm_89. That launch writes the cache through an `fp8e4nv` cast, which Triton
  can't compile on Ampere; the write goes back to `reshape_and_cache_flash`.
- `qwen4exp-ple-fp8-bytecopy`: retired. vllm#60142, in v0.32.0, is the same fix.
- The rest apply unchanged.

Measured 2026-10-18 at 175 W, with vLLM's v0.32.0 release wheel installed into the v0.31.0
image (the v0.32.0 Docker image was not published yet; same torch, CUDA and Python).
`report.sh --full` PASS: verify-full incl. vision 4/4, verify-stress ladder to 240,659
tokens, soak-continuous 0 MiB growth, bench-agentic. `bench.sh`: 126.3 / 171.6 narr/code,
prefill 5,171 @10K / 7,546 @90K, the same as v0.31.0 within noise; decode at 90K depth 148
vs 129 tok/s (one sample each). KV pool 2.23M tokens, as on v0.31.0 (the first boot on a
cold kernel cache got 2.06M: 1.4 GiB more non-torch memory on stage 0).

Quality (`quality-test.sh --full`, benchlocal-cli v0.11.0, on v0.31.0, thinking budget
65,536 at every effort), pass@1 / pass@3 of 150: instruct 123 / 131, low 122 / 135, medium
128 / 139, xhigh 130 / 141. Analysis and raw cards: #1737.

## 2026-10-18 — `vllm/qwen38-flash-next-dual`: one layout, gated to 64 GB cards (PR #1736 review)

- Renamed from `vllm/qwen38-flash-next-dual-cmp170hx`; the compose is now
  `vllm/compose/dual/albucino-autoround-int4-fp8ple/mtp.yml`, container
  `vllm-qwen38-flash-next-dual`. Engine `vllm-stable`, which lists the `qwen4exp` family.
- Ships PP=2 only, with the measured defaults. The `PARALLEL`, `EP`, `COMPILE` and
  `CUDAGRAPH_SIZES` knobs are gone; the compile mode follows `PLE_PLACEMENT` (nvme lean,
  ram stock), as it did by default.
- The entrypoint reads both cards with `nvidia-smi` and refuses to start below 61,440 MiB
  per card, or with fewer than two cards. The message names
  `strata/qwen3.8-flash-next-iq3s-dual` and `bucko-vllm/qwen3.8-flash-next-ple-dual` for
  3090s. Header: `Requires-min-vram-gb: 64`, `Requires-min-gpu-count: 2`,
  `Tensor-parallel: 2` (the card count preflight looks for; the layout stays PP=2).
- Knob names as on the other Qwen3.8 vLLM composes, defaults unchanged: `MAMBA_SSM_DTYPE`
  is now `MAMBA_SSM_CACHE_DTYPE`; new `SERVED_NAME`, `DRAFT_SAMPLE_METHOD` (default greedy,
  vLLM's default and what everything here was measured with), `ASYNC_SCHED`, `OFFLINE`
  (default 1, as the fixed `HF_HUB_OFFLINE=1` was), `PROMPT_TOKENS_DETAILS_ARG`,
  `MAMBA_CACHE_MODE` (default align) and `MAMBA_BLOCK_SIZE`.
- `--disable-custom-all-reduce` dropped: PP=2 runs TP=1 per stage, so there is no all-reduce.
- Booted on the published `vllm/vllm-openai:v0.32.0` image (`sha256:befccf0e…`) at stock
  clocks, 175 W: verify-full PASS incl. vision 4/4; `bench.sh` 122.9 / 170.9 narr/code,
  prefill 5,147 @10K / 7,610 @90K, peak 63.2 / 62.4 GB, KV pool 2,232,041 tokens. Within
  noise of the earlier wheel-in-v0.31.0-image run.
- `docs/UPSTREAM.md`: the overlay rows now name the upstream PRs that cover them (vllm#60234,
  #58815, #49039 / #61405 / #48926 / #59895, #50653), and a row for vllm#61281, the prefix-cache
  miss under concurrent prefills that `--prefix-match-unit 16` makes likely (read from the
  source, not reproduced).
