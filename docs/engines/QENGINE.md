# QEngine — bpx03's engines for Qwen3.8-27B and Qwen3.8-Flash-Next INT4 on RTX 3090s

**Engine id:** `qengine` · **Slug prefix:** `qengine/` · **Status:** two two-card slugs, 🐣 Incubating · **Requires:** NVIDIA RTX 3090 (sm_86 only), ideally three; a driver with CUDA 13.1 support

> ⚠️ **License: PolyForm Noncommercial 1.0.0.** QEngine is free for non-commercial use only; commercial use needs a licence from its author. Check this before you use it.

## What it is

[QEngine](https://github.com/bpx03/QEngine) (Krzysztof Jagus) is an independent C++/CUDA inference engine (`libqengine.so`, about 26k lines) with its own Python server. It is built for one model on one kind of machine: **Qwen3.8-27B INT4** (RedHatAI's compressed-tensors W4A16 checkpoint and its MTP head) on **three RTX 3090s** with tensor parallel 3 over PCIe. It isn't a fork of any engine we ship, so its lineage class is `new` ([ADDING_ENGINES.md](../ADDING_ENGINES.md)).

What it does, from its README:
- **INT4 weights**, repacked at load into tensor-core layouts, with an INT4 GEMV for decode and an INT4 GEMM for prefill.
- **Tensor parallel over PCIe**, with the all-reduces inside the kernels. It uses GPU-to-GPU P2P when the driver grants it, and otherwise a slower path through host memory.
- **MTP speculative decoding**, with 1–7 drafts a step chosen from the measured acceptance. The author also publishes an MTP head fine-tuned on the engine's own answers (`model_mtp_ft.safetensors`, a release asset). It adds **lookup drafts** from the token history.
- **FP8 (e4m3) K / V** in a shared pool per GPU, up to 262,144 tokens a conversation, with prefix and KV reuse and a host-RAM archive of evicted conversations.
- **Continuous batching** of up to 32 sequences, structured output (llguidance), tool calls, and thinking on or off with reasoning-effort levels.
- **OpenAI- and Anthropic-compatible APIs** (`/v1/chat/completions`, `/v1/models`, `/v1/messages`) on port 8080, `/health`, and a dashboard with Prometheus metrics on port 9393.

**Cards:** three are the tuned configuration. The author has measured two (72–85% of the three-card throughput, full 262K context, `QE_MAX_SEQS=32`). One card is experimental: it starts only with `QE_MAX_SEQS` 1–4, for about 85K–112K tokens of context.

**Models:** Qwen3.8-27B, RedHatAI's INT4 only. It reads `weight_packed` / `weight_scale` (compressed-tensors `pack-quantized`), so other INT4 checkpoints don't load, including our AutoRound one (`auto_gptq` packing: `qweight` / `qzeros` / `scales`). That one has the same scheme (int4, symmetric, group 128, the same layers) but a different file layout and different rounding. Its 1.3 release adds a second engine for **Qwen3.8-Flash-Next** (`libqflash.so`), which reads only the author's own INT4 layout ([bpx03/Qwen3.8-Flash-Next-QEngine](https://huggingface.co/bpx03/Qwen3.8-Flash-Next-QEngine), converted from Intel's AutoRound checkpoint). Upstream calls it a preview: tested on one machine, no quality benchmark yet. 1.3-rc4 fixes that engine's INT8 MoE prefill kernel, which now and then gave a few tokens wrong activations, mostly on two GPUs.

## Image

The author publishes `ghcr.io/bpx03/qengine` (text only, about 0.3 GB; the `:vision` tags add the vision encoder and PyTorch, about 3 GB). Each image's `org.opencontainers.image.revision` label names its source commit. The profile pins **`1.3`** by digest (`sha256:b9d1b0af…`, source `d15a4d3a` = git tag `v1.3`), and the launchers will inject it as `QENGINE_IMAGE`.

## Settings

Its own environment variables (the image's entrypoint passes `QE_EXTRA_ARGS` to `server/app.py`):

| Variable | Default | What |
|---|---|---|
| `QE_GPUS` | `0,1,2` | the GPUs, as the container sees them |
| `QE_MAX_SEQS` | 16 | sequence slots, up to 32 |
| `QE_RESERVE_GB` | 1.5 | VRAM left outside the KV pool, per card |
| `QE_KV_ARCHIVE_GB` | 32 | the host-RAM archive of evicted conversations |
| `QE_P2P` | auto | 0 forces the host-memory path |
| `QE_PRESENCE_PENALTY`, `QE_FREQUENCY_PENALTY` | 0 | the penalties of sampled requests that send none (from 1.3-rc4) |
| `QE_LOOP_GUARD_TURNS` | 3 | the cross-turn loop guard (from 1.3-rc4): after this many identical (reply, tool result) turns in a row, the next turn gets a presence penalty on the repeated reply (`QE_LOOP_GUARD_PENALTY`, 1.5) and no lookup drafts; 0 turns it off |
| `QE_LOOP_GUARD_NOTE` | 1 | on a guarded turn, also append a short server note to the latest tool result; 0 drops the note |
| `QE_MTP_FILE` | auto | the MTP head (`model_mtp_ft.safetensors` when present) |
| `QE_MEM_MARGIN_GB` | max(8 GB, 5% of RAM) | the host RAM the archive always leaves free; the archive gives memory back before the OOM killer would end the server (from 1.3) |
| `QE_ALLOW_SHARED_GPU` | 0 | 1 skips the one-engine-per-GPU check (from 1.3). The lock is `~/.cache/qengine/locks/gpu-<uuid>.lock` under the container's own home, so containers only see each other's when they share it |
| `QE_LOG_FILE` | auto | the server's own log, `~/.cache/qengine/logs/<served-name>.log` (64 MB × 4); 0 turns it off (from 1.3) |
| `QE_EXTRA_ARGS` | | `server/app.py` flags, e.g. `--think 0`, `--max-ctx 131072`, `--served-name` |

⚠️ The loop guard is on by default, and it writes into the conversation: on a guarded turn, an agent finds the server's note in its latest tool result. A request with `"loop_guard": false` turns it off for that request.

## Slugs

| Slug | Model and weights | Port | |
|---|---|---|---|
| `qengine/qwen38-27b-dual` | Qwen3.8-27B, `RedHatAI/Qwen3.8-27B-INT4` (`redhat-int4`) | 8197 | the README's two-card setting: `QE_MAX_SEQS=32`, 262K context, MTP up to 7 drafts a step |
| `qengine/qwen38-flash-next-dual` | Qwen3.8-Flash-Next, `bpx03/Qwen3.8-Flash-Next-QEngine` (`qengine-int4`, 128 GB) | 8198 | 16 slots, 262K context, MTP up to 3 drafts a step; about half the expert groups in pinned host RAM, ~130 GB of host RAM at the defaults (upstream's figure) |

Both are 🐣 Incubating. The 27B slug was booted and benched on 2026-10-28 on two 3090s at 230 W: 147.2 / 216.3 tok/s decode (narrative / code), 2,430 prefill @10K and 1,786 @90K, MTP acceptance length 3.4, 23.4 GB a card, verify-full 8 + 2 n/a ([BENCHMARKS.md](../../BENCHMARKS.md)). The Flash-Next slug was booted and benched the same day: 164.0 / 170.6 tok/s decode, 1,921 prefill @10K and 2,373 @90K, MTP acceptance length 2.8, 24.1 GB a card, host RAM 88 GB at ready (up to ~114 GB as the archive fills), verify-full 8 + 2 n/a.

Community PR #1836 (eddietheengineer) validated both slugs on another two-card rig and found two Flash-Next problems there: a NaN on a ~76K-token prefill with `FLASH_COMM=auto`, and an out-of-memory in the 8-pack's agent pack at 8 slots. Its fixes are `FLASH_COMM=ce` and `FLASH_MAX_SEQS=4`. Neither reproduced on the reference rig: 90K and 107K needles on `auto`, which picked the P2P path here, and 8 concurrent multi-turn conversations to 27.7K tokens at the default 16 slots. So the defaults stay, and the compose header names both settings.

On the 27B, the engine is faster with the two v1.0 release assets in the weights folder (`token_rank.bin`, `model_mtp_ft.safetensors`); `setup.sh` doesn't fetch them, so the compose header and the weights entry give the `gh release download` line.

The composes give the container only the two chosen cards (`device_ids`, so `launch.sh --gpus` picks them) and set `QE_GPUS=0,1`, the cards as the container numbers them. QEngine's own entrypoint overrides `CUDA_VISIBLE_DEVICES` with `QE_GPUS` (default `0,1,2`), so a forwarded mask would not reach it. The engine cache (`~/.cache/qengine`: the GEMM tune table, stats, logs and the one-engine-per-GPU locks) is mounted from the engine cache directory, so the GEMMs are tuned once per image.

## Thinking and effort

Our knobs reach QEngine's server flags through `QE_EXTRA_ARGS`:

| Knob | QEngine | |
|---|---|---|
| `ENABLE_THINKING` | `--think 1` / `0` | the default for requests that set none; `true` unless set |
| `SPEC_N` | `--mtp-k <n>` | the most MTP drafts a step (the engine adapts below it); 0 turns MTP off, lookup drafts stay on |
| `REASONING_EFFORT` | a copy of the template | `low` unless set; `low`, `medium` or `xhigh` |

QEngine serves its own copy of the Qwen3.8 chat template (`server/templates/qwen38_syssafe.jinja`), whose default effort is `xhigh`, and its server has no flag for that default. So the compose copies the template at boot with its one `reasoning_effort|default('xhigh')` replaced by the chosen effort, and serves the copy with `--template`. It refuses to start if that literal isn't there exactly once, so a future image can't quietly go back to `xhigh`. A request's own effort still goes to QEngine's template, which maps `high` to `xhigh` and anything else outside the three, `minimal` and `max` included, to `medium` (our patched template on the vLLM and SGLang slugs maps `minimal` to `low` and `max` to `xhigh`).

QEngine has no thinking budget: no flag, variable or request field caps the thinking, so `THINKING_BUDGET_*` and `THINKING_BUDGETS` don't apply to these slugs (`knob-conformance.json`).

## What's wired

- the engine profile (`scripts/lib/profiles/engines/qengine.yml`);
- engine kind `qengine` in `scripts/lib/engine-kind.sh`, from its id, its profile `type`, a `qengine-` container name, its image and `/v1/models` `owned_by: "qengine"` (it sends no `system_fingerprint`);
- container discovery (`qengine-` in the prefix set; port 8080 counts with that evidence);
- the `QENGINE_IMAGE` arm in both launchers;
- the label in `health.sh`, the Genesis skip in `verify-full.sh`, and the kind in `report.sh`, `run_context.py` and the local registration types;
- the two slugs, their weights variants and the launch knobs above.

QEngine prints `[stats]` lines for log parsers, in llama.cpp's timing format and vLLM's `SpecDecoding metrics` format, so `bench.sh`'s engine-side timings and acceptance capture and `verify-full.sh`'s MTP acceptance check read it with no QEngine-specific code (checked on the 27B slug, 2026-10-28).

**Not wired yet** ([ADDING_ENGINES.md](../ADDING_ENGINES.md), "CONTRACT — wiring it into the tooling"):
- `bench.sh`'s interconnect report doesn't read QEngine's `P2P:` line, so it says it sees no P2P engagement; `health.sh` isn't checked against QEngine;
- the metrics and dashboard port (9393), which the composes don't publish;
- a boot of the Flash-Next slug;
- c3's own engine-family handling.
