# bucko-vllm — DominikBucko's Qwen3.8-Flash-Next runtime for 2× RTX 3090

**Engine id:** `bucko-vllm` · **Slug prefix:** `bucko-vllm/` · **Status of its slugs:** 🐣 Incubating · **Requires:** 2× 24 GB NVIDIA, sm_86+, and a lot of host RAM (135–170 GB)

## What it is

[DominikBucko/qwen38-flash-next-2x3090](https://github.com/DominikBucko/qwen38-flash-next-2x3090) (Apache-2.0) is a vLLM derivative written for one model: Qwen3.8-Flash-Next on two 3090s. It starts from vLLM's own day-0 image for that model (`vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece…`, `vllm 0.1.dev20073+g8e685d198`) and replaces about 48 files on top of it:
- PLE offload: the per-layer embedding table is held in host RAM;
- an expert cache in the WNA16 MoE method: a static hot set plus a dynamic LRU, with the rest of the experts offloaded over UVA;
- humming MoE kernels;
- MTP with three draft tokens and hybrid-state rollback.

The expert cache is where its speed comes from. Stock vLLM with the same offload flags ran Swift-1.5 at about 16 tok/s; bucko runs it at about 85 (see the compose headers).

It is kept as its own engine, `type: vllm`, `lineage.relation: derivative`. Don't fold it into `vllm-stable` or repoint its composes at another vLLM profile.

## Image

The author's official CI-built GHCR release image, with a build-provenance attestation, pinned by digest in `scripts/lib/profiles/engines/bucko-vllm.yml`. Today that's v0.5.0, `ghcr.io/dominikbucko/qwen38-flash-next-2x3090@sha256:75adfc64…`, whose OCI labels give source revision `e7279ab7` (tag v0.5.0). The launchers inject it as `BUCKO_IMAGE`. Export `BUCKO_IMAGE` in the shell to try another build for one launch; a saved value loses to the pin.

**Bumping:** move the digest to a newer bucko release, then boot both slugs through `switch.sh` and check the `[thinking-budget-default]` boot line (below). Re-read the release notes for changes to the launcher's environment variables, which the composes set.

## Slugs

| Slug | Weights | Host RAM | Notes |
|---|---|---|---|
| `bucko-vllm/qwen3.8-flash-next-ple-dual` | albucino's W4A16 AutoRound + FP8 PLE hybrid (129 GB, includes the compact INT4 MTP draft) | ~135 GB | the recipe as published |
| `bucko-vllm/qwen3.8-flash-next-swift15-dual` | UkisAI's Swift-1.5 fine-tune, W4A16 AutoRound + BF16 PLE (177 GB) | ~170 GB | borrows albucino's draft: the companion variant `albucino-mtp-int4-g32`, which `setup.sh <slug>` fetches |

Both are single-stream by design (`max_num_seqs=1`), 262K context, bf16 KV with the pool pinned by `KV_CACHE_MEMORY_BYTES`, so `mem_util` in the registry is only nominal. Measurements, dates and the settings they were taken at are in each compose's header. Launch with `--force` while they're 🐣.

## What club-3090 adds

- **A default thinking budget** (`patches.yml` → `bucko-default-thinking-budget`): `models/qwen3.8-flash-next/bucko-vllm/patches/default-thinking-budget/apply.py` makes a request without `thinking_token_budget` get `THINKING_TOKEN_BUDGET` (default 16384), because vLLM can't take one as a server default. The core `vllm-default-thinking-budget` patch is a hardened port of this one, but it doesn't load on bucko's vLLM base, which lacks `SamplingParams.trace_decode_token_ids`. There is no effort map: `REASONING_EFFORT` and `THINKING_BUDGET_*` aren't read.
- **Sizing for 32 GB cards** (ple slug): bucko's `CPU_OFFLOAD_GB=30` is a 24 GB value, and two 5090s left ~7.5 GiB per card idle at it ([#1700](https://github.com/noonghunna/club-3090/discussions/1700)). `switch.sh` lowers it to 22 when every card has at least 31,130 MiB free at launch, and prints a `[cpu-offload]` line saying what it chose and why. 22 is @paulp83's measured value on 2× RTX 5090 (bucko upstream [issue #7](https://github.com/DominikBucko/qwen38-flash-next-2x3090/issues/7): decode +12–17%, prefill +25%, 29.3 / 30.4 GiB peak), first taken on an older bucko build at hot cache 88. He re-measured it through this sizer on the pinned v0.5.0 image at hot cache 84: decode 124.7 / 133.7 tok/s against 120.3 / 117.7 at 30, one boot each, 29,290 / 29,831 MiB per card after the bench ([BENCHMARKS](../../BENCHMARKS.md)). It is the only measured point, so larger cards get 22 too. A `CPU_OFFLOAD_GB` you set yourself always wins. The Swift-1.5 slug has no measured point and keeps 30. The rules are in the compose header and `resolve_cpu_offload_gb` (`scripts/lib/compose-meta.sh`).
- The club conventions every compose follows: `umask 0002` and the host GID on the cache mounts, the `CLUB3090_RESTART` knob, `BIND_HOST` / `ESTATE_PORT` / `ESTATE_CONTAINER`.

## Known gaps

- Quality isn't validated: one thinking-leg 8-pack on the Swift 1.5 slug (effort xhigh, 2026-10-07: 126/150 pass@1, [BENCHMARKS.md](../../BENCHMARKS.md)), no instruct leg, and nothing on the albucino slug.
- Streaming tool calls are unverified. On stock vLLM, MTP drops streamed tool calls under `tool_choice: "required"` (empty `tool_calls`, `finish_reason: stop`; `auto` was clean), and bucko drafts with MTP. The upstream PR (vllm#39598) was closed on 2026-06-18 without merging, as "fixed on main", but the fix isn't named and nobody has re-measured since: not on our vLLM pin, and not on bucko (`scripts/stream-toolcall-probe.py`). benchlocal's packs don't stream, so an 8-pack won't show it. See [UPSTREAM.md](../UPSTREAM.md) → vllm#39598.
- No P2P custom all-reduce on the reference rig, so decode trails the author's own numbers.
- Its `VLLM_PREFIX_CACHE_RETENTION_INTERVAL=1600` (the author's value) opts into sparse prefix-cache retention on a hybrid model running MTP. Upstream vLLM reverted that default for this combination; A/B it before trusting prefix-cache numbers (compose comment).
