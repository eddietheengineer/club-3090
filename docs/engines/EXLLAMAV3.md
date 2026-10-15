# ExLlamaV3 (exl3) + TabbyAPI — CPU-**computed** MoE expert offload

## ⚠️ Read this first: what this is, and what it isn't

This is a **🐣 Incubating** engine on this stack, catalogued 2026-09-17. It serves
Qwen3.8-Flash-Next with **zero patches** — the only frontier-MoE path here that runs
stock upstream — but it has **not** cleared the gates a `✅ Production` slug clears:

| Gate | Status |
|---|---|
| Boots, serves, coherent output | ✅ validated in the shipped container |
| Tool calling · reasoning · vision | ✅ |
| Built-in MTP speculative decoding | ✅ acceptance 0.688 |
| `bench.sh` canonical throughput | ✅ (see below) |
| **Quality 8-pack** | ⛔ **never run — deliberately left to the community** |
| verify-stress · soak-continuous | ⛔ never run |
| Concurrency curve | ⛔ never run (C=1 only) |
| Context | ✅ 204800 shipped with Q4 KV, booted and benched here (the model declares 262144) |

**The missing 8-pack is the important one.** The faster of the two shipped slugs is
**3.05bpw**, and part of why it is fast is simply that it is small. Nobody has measured
what that costs in output quality. If you run one, please report numbers — that is
exactly why these ship 🐣 rather than hidden.

---

## TL;DR — why this engine is interesting

⭐⭐ **exl3 COMPUTES offloaded MoE experts on the CPU.** Expert weights never cross
PCIe; only activations do. Every other offload path on this stack moves weights to the
GPU and is therefore bandwidth-bound. exl3 is bound by **host compute** instead.

That single fact inverts the tuning model:

| Engine | The lever |
|---|---|
| moe-cache (llama.cpp fork) | **hit rate** — keep hot experts resident, pay a PCIe cost on a miss |
| **exl3** | **CPU-resident fraction** — the host computes that share, every token |

Measured on one rig, one engine, three configurations:

| Model | bpw | experts CPU-resident | narrative decode |
|---|---|---|---|
| Qwen3.8-Flash-Next | 3.05 | **25%** | **57.37** |
| Qwen3.8-Flash-Next | 4.05 | 44% | 48.53 |
| GLM-5.3-Flash | 4.05 | **80%** | **10.9** |

During GLM decode **GPU utilisation was 5–8% on both cards** — they were idle, waiting
on an AVX2 core pool doing 80% of the FFN work.

### ⭐ The selection rule — apply it BEFORE you download

Estimate `bpw × params` against your total VRAM to get the CPU-resident expert fraction:

- **under ~30%** → exl3 is competitive-to-excellent
- **over ~50%** → use an engine with a real expert cache; exl3's `-mcs` splits by
  expert *index* (tail-N to CPU) with a slow rebalancing sweep, so it cannot win when
  most experts must live off-card

GLM-5.3-Flash was evaluated on this engine and **rejected** on exactly this basis. It
worked perfectly — vision 4/4, tools, MTP at 57%, reasoning — and still lost to the
shipped moe-cache config (10.9 vs 15.45) because it needs 80% of experts on the host.
That download was avoidable, and the rule above is what would have avoided it.

---

## Hardware support

⭐ **Ampere (sm_86) is first-class here.** exl3's kernels are hand-written for its
trellis codebook and carry no FA3, fp8-native or NVLink-allreduce dependency, so none
of the sm_90+ gates that block other engines apply. Prebuilt
`cu132 / torch2.11.0 / cp312` wheels — **no build, no patches**.

⚠️ The CPU tier is the ceiling. The reference rig is **AVX2 (Zen 3, no AVX-512)**, and
since the host does the expert FFN, an AVX-512 box is a different performance class.
Nothing here has been measured on one.

---

## Quick start

```bash
# 3.05bpw — the faster tier (85 GB of weights, ~96 GB of host RAM)
THREADS=28 bash scripts/switch.sh --force exllamav3/qwen38-flash-next-dual-exl3-305-cpumoe

# 4.05bpw — the more conservative bit rate (107 GB of weights, ~118 GB of host RAM)
THREADS=28 bash scripts/switch.sh --force exllamav3/qwen38-flash-next-dual-exl3-405-cpumoe
```

`--force` is required: 🐣 Incubating slugs are non-functional by the launcher's
definition and are hidden from `switch.sh --list` unless you pass `--all`. With
`launch.sh` the form is `FORCE=1 bash scripts/launch.sh --variant <slug>`
(`launch.sh … --force` fails with *Unknown flag*). `THREADS=28` is the reference
rig's value; see lever 1 below for yours.

⚠️ **The quant tier is an HF *branch*, not a subfolder.** turboderp publishes one branch
per bpw off a near-empty `main`, so the `revision:` pin in the model profile is
load-bearing. Note also that **3.05 is `_h5_ng5` while 4.05 is `_h6_ng6`** — the
suffixes differ, and the two branches ship different file sets (3.05 has an MTP patch
file, 4.05 factors the vision tower into `vision_k6.safetensors`).

---

## Measured

`bench.sh` canonical protocol, 2× RTX 3090, 28 threads, 2026-09-17, in a **host venv** at
32768 ctx, FP16 KV and split 128. That isn't the shipped config:

| Slug | narrative | code | prefill@10K | TTFT |
|---|---|---|---|---|
| `…-305-cpumoe` (3.05bpw) | **57.37** (CV 1.8%) | **74.51** (CV 2.3%) | **1566.0** (CV 0.9%) | 310 / 315 ms |
| `…-405-cpumoe` (4.05bpw) | 48.53 | 62.94 | 1335.7 | — |

The shipped container at its own config (3.05bpw, 204800 ctx, Q4 KV, split 144,
`THREADS=28`), 2026-09-18:

| | narrative | code | TTFT |
|---|---|---|---|
| `…-305-cpumoe` | **61.60** (CV 0.6%) | **79.86** (CV 2.3%) | 279 / 311 ms |

⚠️ **No like-for-like venv-vs-container comparison has been run:** the two tables differ in
context, KV mode and split. An earlier version of this page said the container was ~9% slower
than the venv. That was a compose bug, retracted 2026-09-18: the composes had no
`environment:` block, so `THREADS` never reached the container, which ran 16 threads against
the venv's 28 (52.19 / 68.11 at 16 threads). The boot log says which thread count it took:
`[threads] --cpu-moe-threads 28 (THREADS set explicitly)`.

### Against bucko-vllm

Measured on the reference rig on different dates and configs:

| | bucko, an earlier build (before 09-17) | **bucko v0.5.0 (10-06)** | exl3 3.05bpw, venv (09-17) | exl3 3.05bpw, container (09-18) |
|---|---|---|---|---|
| narrative | 68.12 | **79.5** | 57.37 | 61.60 |
| code | 74.09 | **83.1** | 74.51 | 79.86 |
| prefill@10K | ~565 | **1,623** | 1,566 | not measured |
| TTFT | 546 / 556 ms | not measured | 310 / 315 ms | **279 / 311 ms** |

⇒ Against the earlier build, exl3 tied bucko on code and led on prefill and TTFT.
**bucko v0.5.0 changed that:** it now leads on decode, and its prefill matches exl3's.
exl3's remaining case is less host RAM (~96 GB for 3.05bpw vs ~135 GB for bucko's albucino
slug) and a TTFT edge that hasn't been re-measured against v0.5.0. On a 2× 5090 rig bucko decoded ~1.9× faster
([#1542](https://github.com/noonghunna/club-3090/issues/1542)).

---

## Tuning levers, in order of impact

### ⭐⭐ 1. `--cpu-moe-threads` — the biggest knob, and the default is wrong

| threads | narrative | code |
|---|---|---|
| 16 (≈`nproc/2`) | 40.98 | 47.73 |
| 24 | 46.56 | 59.59 |
| **28** | **49.48** | **57.88** |

**16 → 28 is +20.7% / +21.3%.** The good zone is an **absolute ~24–32 threads**, not a
fraction of core count. The composes ship `nproc/2` as a *portable floor* and say so at
boot — set `THREADS=<n>` to tune.

⭐ This reproduces the llama.cpp thread finding on a completely different engine. Two
independent engines converging on the same absolute window means it is a property of
the **host memory subsystem**, not of either engine. Sweep it first on any CPU-offload
engine, before touching anything else.

### ⭐ 2. `--dynamic-draft` — worth +7.8% on code

At 28 threads, `--draft-num-tokens 4` with `--dynamic-draft true` vs a fixed `k=2`:
**−2.8% narrative but +7.8% code.** Under `dynamic_draft`, `draft_num_tokens` is a
**ceiling, not a depth** — the engine shortens the draft when confidence drops.

⚠️ **Therefore a depth number alone does not identify a config.** Log the whole draft
block. An unattributed ~12% gap between the 4.05 first boot and its tuned arms is most
likely exactly this: that boot recorded only "MTP n=4".

### ⭐ 3. `--cpu-moe-split-experts` — a TIER choice, not a tuning knob

Sweeping it within a tier (225–256 on 4.05bpw) measured essentially nothing. Changing
the **bit rate** 4.05 → 3.05 moved the CPU-resident share 44% → 25% and bought **+18%
on narrative, code AND prefill simultaneously**. Choose the bit rate that lands the
split where you want it, then leave the knob alone.

---

## ⚠️ Traps

**1. `/dev/shm` — the container-only one that looks like a model failure.**
exl3's CPU-MoE handoff segment is POSIX shared memory. Docker defaults `/dev/shm` to
64 MiB; the segment wanted 68.1 MiB. The model **loads, reports healthy**, and then
every generation aborts with *"chat completion aborted. Maybe the model was unloaded?"*
— which points at entirely the wrong thing. The composes ship `shm_size: "2gb"`. Do not
trim it: the segment scales with `cpu_moe_split_experts`.

**2. Only `verify-full` reads the drafter counter.**
TabbyAPI serves a llama.cpp-compatible `/props` and emits no `system_fingerprint`, so
`verify-full` used to classify exl3 as `llamacpp`, skip its spec-dec check and read as
"no drafter". Fixed 2026-09-18: it now takes the engine from the container or image name
when they name one, and derives acceptance from the `draft N/M` lines in `docker logs`.
`bench.sh` and `health.sh` still don't report exl3's acceptance: read
`draft N/M accepted` from `docker logs` yourself.

**3. Don't build the image from a live tabbyAPI checkout.**
Upstream's `.dockerignore` excludes `venv` but **not `.venv`**, and excludes
`config.yml` but **not `config-*.yml`**. A working-tree build bakes in a multi-GB venv
and any local configs. Build from `git archive HEAD`.

**4. Autosplit is not always right.**
It was accurate on Qwen3.8-Flash-Next (cards within ~30 MiB). On GLM-5.3-Flash it left
a 3.0 / 7.8 GiB imbalance and needed a manual `--gpu-split`. Check your cards after the
first boot.

**5. The n-gram table is disk-streamed by default.**
Qwen's PLE / n-gram table (32.6 GB at 3.05bpw, 39.0 GB at 4.05bpw) is **never in VRAM** on any setting. Upstream streams it
from disk; `--ngram-ram true` (what the composes ship) holds it in system RAM instead.
On a RAM-constrained box, drop it and accept the latency.

---

## What's in this image

**Nothing of ours.** `ghcr.io/noonghunna/tabbyapi-club3090` is stock
[theroyallab/tabbyAPI](https://github.com/theroyallab/tabbyAPI) @ `53da791`, built with
**upstream's own** `docker/Dockerfile.cu13`, which resolves to `torch 2.11.0+cu130` and
`exllamav3 1.5.0+cu132.torch2.11.0`. Zero patches, zero vendored overlays. The digest
pin exists for reproducibility, not to protect patch hooks.

⚠️ **ATTRIBUTION:** ExLlamaV3 and the official quants are
[turboderp's](https://github.com/turboderp-org/exllamav3) work; TabbyAPI is
theroyallab's. We vendor neither and patch neither — what we contribute is measurement.

---

## What is NOT validated

- **Quality, at either bit rate.** No 8-pack. This is the headline gap.
- verify-stress, soak-continuous, any concurrency above C=1.
- Context above the shipped 204800 on 2× 24 GB. The model declares 262144; a 2× 5090 rig
  filled 240,660 of it ([#1542](https://github.com/noonghunna/club-3090/issues/1542)).
- KV above Q4. The composes ship Q4 (`KV_TYPE`, exl3's modes are FP16 | Q8 | Q6 | Q4),
  chosen to maximise context, and that is below this stack's q8 serving floor. The expert
  split's VRAM fit is calibrated to Q4 at 204800, so Q8 or FP16 at that context hasn't been
  booted; lower `CTX` with them.
- Tensor parallelism. These slugs use autosplit layer-split; `tensor_parallel` is false.
- Any model other than Qwen3.8-Flash-Next. GLM-5.3-Flash was tried and rejected.
