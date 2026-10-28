# QEngine — bpx03's engine for Qwen3.8-27B INT4 on RTX 3090s

**Engine id:** `qengine` · **Slug prefix:** `qengine/` · **Status:** wired, two 🐣 Incubating slugs (`qengine/qwen38-27b-dual`, `qengine/qwen38-flash-next-dual`) · **Requires:** NVIDIA RTX 3090 (sm_86 only), ideally three; a driver with CUDA 13.1 support

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

**Models:** Qwen3.8-27B, RedHatAI's INT4 only. It reads `weight_packed` / `weight_scale` (compressed-tensors `pack-quantized`), so other INT4 checkpoints don't load, including our AutoRound one (`auto_gptq` packing: `qweight` / `qzeros` / `scales`). That one has the same scheme (int4, symmetric, group 128, the same layers) but a different file layout and different rounding. Its 1.3 release adds a second engine for Qwen3.8-Flash-Next (`libqflash.so`, the author's own INT4), an experimental preview that the profile doesn't list yet. 1.3-rc4 fixes that engine's INT8 MoE prefill kernel, which now and then gave a few tokens wrong activations, mostly on two GPUs.

## Image

The author publishes `ghcr.io/bpx03/qengine` (text only, about 0.3 GB; the `:vision` tags add the vision encoder and PyTorch, about 3 GB). Each image's `org.opencontainers.image.revision` label names its source commit. The profile pins **`1.3`** by digest (`sha256:b9d1b0af…`, source `d15a4d3a` = git tag `v1.3`), and the launchers will inject it as `QENGINE_IMAGE`. Both slugs were re-booted on `1.3` (2026-10-28): the 27B slug passes the full gate (verify-full / bench / stress / soak / 8-pack both legs); the Flash-Next slug passes verify-full / bench / stress / continuous soak and the thinking-OFF 8-pack with `FLASH_COMM=ce` + `FLASH_MAX_SEQS=4` (see the two warnings below).

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
| `QE_EXTRA_ARGS` | | `server/app.py` flags, e.g. `--think 0`, `--max-ctx 131072`, `--served-name` |

⚠️ The loop guard is on by default, and it writes into the conversation: on a guarded turn, an agent finds the server's note in its latest tool result. A request with `"loop_guard": false` turns it off for that request.

⚠️ **Flash-Next prefill NaN on the P2P SM path (measured 2026-10-28, 2× 3090 PCIe).** With `FLASH_COMM=auto` (the default) the interconnect probe picks the P2P SM load/store path, and prefills then produce non-finite `lm_head` inputs — observed at positions 10,273 / 12,859 / 13,335 / 76,418 / 85,894 tokens (deterministic per prompt; short completions unaffected). The guard fails the request (HTTP 500) and, after 5 faults in 5 minutes, exits ("shared state is likely corrupt"). Measured **identical on 1.3 and 1.3-rc4** — same positions, same block counts — so it is the SM path, not a release regression. `FLASH_COMM=ce` (copy-engine transfers) measured clean: zero faults across every ce boot (bench's 90K step, stress's 91K needle, 4×76K probes); the flash-next compose ships it as the default. Filed upstream: [bpx03/QEngine#2](https://github.com/bpx03/QEngine/issues/2) — track the row in [`docs/UPSTREAM.md`](../UPSTREAM.md).

⚠️ **Flash-Next VRAM OOM under concurrency (measured 2026-10-28, 2× 3090).** The QE-INT4 weights + 51.8 GB pinned n-gram table leave only ~0.25 GiB free per card — that is the engine's own `FLASH_EC_MARGIN_MB` default (256 MB) — and CUDA-graph instantiation needs more than that. At `FLASH_MAX_SEQS=8` the 8-pack's hermesagent-20 exhausts it (`graph instantiate out of memory` → `cudaErrorMemoryAllocation at gemm.cu:3456` → abort); at 4 slots thinking-OFF passes (117/150) but thinking-ON still cliffs (`flash_batch.cuh:704`). The compose ships **`FLASH_MAX_SEQS=1`** — one long-context stream, which is this slug's declared workload — and hermesagent-20 thinking-ON passes clean at 1 slot + 131K (12/20, restarts=0). ⚠️ **Shrinking `--max-ctx` does not create headroom**: at 64K the boot still reports 0.25 GiB free, because the expert-cache allocator absorbs the freed VRAM. Slots (recurrent state + per-shape graph pools) are the real lever; `FLASH_EC_MARGIN_MB` is the other.

## What's wired

- the engine profile (`scripts/lib/profiles/engines/qengine.yml`);
- engine kind `qengine` in `scripts/lib/engine-kind.sh`, from its id, its profile `type`, a `qengine-` container name, its image and `/v1/models` `owned_by: "qengine"` (it sends no `system_fingerprint`);
- container discovery (`qengine-` in the prefix set; port 8080 counts with that evidence);
- the `QENGINE_IMAGE` arm in both launchers;
- the label in `health.sh`, the Genesis skip in `verify-full.sh`, and the kind in `report.sh`, `run_context.py` and the local registration types;
- **acceptance + throughput parsing:** the server's `[stats] SpecDecoding metrics: Mean acceptance length: …` lines are the vLLM-modern wording, so `capture.sh`'s acceptance parser and `verify-full.sh`'s MTP check read them unchanged (measured: accept-len 6.39 on the 27B slug, 3.97 on Flash-Next);
- **the launch knobs mapped onto its own names** — `ENABLE_THINKING` → `--think 1|0` and `SPEC_N` → `--mtp-k N` (0 = drafts off), both resolved in the composes' entrypoint, which validates the domain and stops the boot on a bad value; a flag already named in `QE_EXTRA_ARGS` wins. `REASONING_EFFORT` and the `THINKING_BUDGET_*` knobs are **unsupported**: QEngine has no server-side default for effort (it is a per-request `chat_template_kwargs.reasoning_effort`) and no token budgets at all (the effort levels are prompt instructions, not caps) — declared with this section as the source in `knob-conformance.json`;
- weights variants `bpx03-qengine-int4` on both models (`RedHatAI/Qwen3.8-27B-INT4`, `bpx03/Qwen3.8-Flash-Next-QEngine`);
- the composes, booted on this rig (two 3090s, P2P granted) with verify-full 10/10 each on the 1.3 pin.

**Left for later:** c3's own engine-family handling, and the Flash-Next promotion review past 🐣 (with the two compose fixes above, verify-full / bench / stress / continuous soak / the 8-pack both legs run clean at 1 slot + 131K; concurrency beyond one stream is the rig-ceiling trade).
