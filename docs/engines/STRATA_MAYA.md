# Project Maya — a Strata fork for GLM-5.3-Flash on one, two or four cards

**Engine id:** `strata-maya` · **Slug prefix:** `strata-maya/` · **Status of its slugs:** 🐣 Incubating · **Requires:** NVIDIA compute capability 7.5+, driver ≥ 580 (CUDA 13), an x86-64 CPU with AVX2, and enough host RAM to hold the experts that don't fit in VRAM (~65 GB for Maya-S on two cards up to ~148 GB for Maya-L on one, measured; less RAM still runs, reading the rest from the model files)

## What it is

[Project Maya](https://github.com/mw00/project-maya) (MIT, mw00) is a fork of [Strata](https://github.com/Niko1221/Strata) rewritten for one model, Z.ai's GLM-5.3-Flash (320.76B MoE), with its own quants ([peasantsmith/GLM-5.3-Flash-Maya-GGUF](https://huggingface.co/peasantsmith/GLM-5.3-Flash-Maya-GGUF)). It keeps Strata's shape: a C++/CUDA engine (`build/strata`) with ggml's CPU backend as a library, and a Python server (`serve/server.py`) on port 8080 with an OpenAI API (`/v1/chat/completions`), an Anthropic one (`/v1/messages`) and a dashboard.

Where the experts live:
- **VRAM:** a per-layer expert pool on each card, filled from a shipped routing profile and promoted as it runs;
- **host RAM:** a pinned tier sized from the memory free at start;
- **the model files:** whatever fits in neither, read while it answers.

Each token's RAM-tier experts are split between the CPU (computed in place) and PCIe copies to the GPU, priced per expert at start. On several cards it splits the **layers** (`--layer-split auto`, a placement search over the cards' free VRAM), and on two or more it drafts with the model's own MTP (NextN) block, the cards working on consecutive tokens. No NCCL and no P2P.

Its profile declares `type: strata` and `lineage.relation: fork` (base `strata`); its id carries the family prefix, so the tooling knows it as engine kind `strata` (`scripts/lib/engine-kind.sh`): container names `strata-maya-…`, image `strata-maya-club3090`.

## Image

Maya publishes no image, no Dockerfile and no Linux engine: `maya.sh` compiles on the user's PC. So club-3090 builds `ghcr.io/noonghunna/strata-maya-club3090` for each release, an image-provenance exception recorded in [ADDING_ENGINES.md](../ADDING_ENGINES.md).
- **Build:** our own Dockerfile compiles the engine the way `maya.py` does, with upstream's `STRATA_PORTABLE=ON` (ggml's CPU code for an AVX2 baseline instead of the build machine's CPU) and a fixed arch list. The runtime stage carries the release's files, llama.cpp's `gguf-py` and the server's Python packages.
- **Archs:** `75;80;86;89;120` (RTX 20–50 and the A-series). V100 needs CUDA 12, which this image can't build; Maya's own setup builds it natively.
- **Text only:** neither the vision encoder nor the DFlash2 drafter (CC BY-NC-ND weights) is in the image.
- **Recipe, checks, CI workflow and pin flow:** [models/glm-5.3-flash/strata-maya/image/](../../models/glm-5.3-flash/strata-maya/image/README.md).

The profile pins a digest, and the launchers inject it as `STRATA_MAYA_IMAGE`. Export `STRATA_MAYA_IMAGE` in the shell to try another build for one launch; a saved value loses to the pin.

**Bumping:** CI publishes each new release (`:<tag>`, `:sha-<commit>`), but publishing doesn't pin. To move the pin:
1. boot a dual and a single slug on the new digest through `switch.sh`;
2. run `verify-full` on each;
3. run `scripts/engine-pin-bump.sh strata-maya ghcr.io/noonghunna/strata-maya-club3090@sha256:<digest>` and update `lineage.source_ref`.

A release that renames a flag the launcher passes (`serve/server.py`, `tools/iq_pack.py`) fails the image build, so the recipe and the launcher move together.

## Slugs

| Quant | Single (1 card) | Dual (2 cards) | Multi4 (4 cards) |
|---|---|---|---|
| **Maya-S v2** (`maya-s`, IQ2_XXS experts, 96.5 GB) | `strata-maya/glm53-flash-single-maya-s` · 8027 | `strata-maya/glm53-flash-dual-maya-s` · 8026 | `strata-maya/glm53-flash-multi4-maya-s` · 8028 |
| **Maya-M** (`maya-m`, IQ2_S experts, 116 GB) | `strata-maya/glm53-flash-single-maya-m` · 8035 | `strata-maya/glm53-flash-dual-maya-m` · 8029 | `strata-maya/glm53-flash-multi4-maya-m` · 8037 |
| **Maya-L** (`maya-l`, IQ3_S experts, 156.3 GB) | `strata-maya/glm53-flash-single-maya-l` · 8044 | `strata-maya/glm53-flash-dual-maya-l` · 8043 | `strata-maya/glm53-flash-multi4-maya-l` · 8045 |

- **Weights:** Maya's own quants from `peasantsmith/GLM-5.3-Flash-Maya-GGUF` (revision `f16ee4ba`), one folder per quant under `glm-5.3-flash-maya-gguf/`. Each carries the MTP draft block. Upstream's quality figures (KL against the FP8 model on held-out text, its own harness): Maya-L 0.188, Maya-M 0.291, Maya-S 0.428. Smaller quants fit more experts in VRAM, so they decode faster.
- **multi4 is never booted on the reference rig** (two cards): community-validated by design. Its numbers come from community reports.
- **One card has no drafting:** the MTP block runs only on two or more GPUs.

**Data volume:** `strata-maya-data` under the data directory (`~/.local/share/club-3090` by default; `STRATA_MAYA_DATA_DIR` overrides), one folder per quant: a symlink per shard, Maya's pack (its index of the model files, ~1 GB, written next to the shards as the engine expects) and the config.

**First start:** the launcher checks each shard's SHA-256 against Maya's own table (a few minutes for 100–156 GB, once; again only when a file's size or time changes) and builds the pack (a minute or a few, once). Later starts take about 30 seconds on the reference rig. `SETUP_ONLY=1` runs just that; `REPACK=1` builds the pack again; `VERIFY=0` skips the hash check.

**RAM:** Maya sizes its RAM tier from the memory free at start. Drop the page cache first on a box that just read big files, or the tier comes out smaller than it could be. On a host with less RAM than the measured figure, the experts that don't fit are read from the model files while it answers (slower; not measured here).

**Requests and readiness:** one request at a time. `switch.sh`'s readiness probe (one completion) passes once the server prints `ready: http`.

Measurements, with dates and settings, are in each compose's header and in [BENCHMARKS.md](../../BENCHMARKS.md) (GLM-5.3-Flash, the Project Maya table).

## What club-3090 adds

- **A launcher for every compose** (`models/glm-5.3-flash/strata-maya/launcher/`: `maya-entrypoint.sh` and `maya_prepare.py`). Maya's own setup isn't used in the image. The model folder is mounted read-only, but Maya writes its pack next to the shards, so the launcher links the shards into a folder of their own on the data volume, checks their SHA-256 there, builds the pack with Maya's `tools/iq_pack.py` (and stamps it as `maya.py` does, so a changed shard rebuilds it), writes the config and starts `serve/server.py` on the cards `MAYA_GPUS` names. The compose passes the quant as the launcher's one argument, not as a setting, so no saved value can point a slug at another quant's pack.
- **Calibration knobs:** `MAYA_PCIE_SHARE` and `MAYA_CPU_LANE` become the engine's `STRATA_GLM_PCIE_SHARE` / `STRATA_GLM_CPU_LANE` when set. They are what Maya's own `maya.sh --calibrate` tunes for a PC; the composes ship the engine's own choice.
- **Runtime numbers from `/metrics`.** Maya serves Strata's `/metrics` document (its version in `engine.maya_version`), but its draft counts are only in its engine log (`/data/<quant>/maya.log`, "glm spec: N of M drafts accepted"). Given the container, `scripts/lib/strata_metrics.py` sums them, so `health.sh`, `verify-full` (its MTP acceptance check), `bench.sh` and `report.sh` read Maya's drafts the way they read Strata's.
- **The club conventions:** the `CLUB3090_RESTART` knob, `BIND_HOST` / `ESTATE_PORT` / `ESTATE_CONTAINER` / `ESTATE_GPUS`, and the host GID plus `umask 0002` on the data volume.

## Known gaps

- **Quality:** not validated here (no 8-pack yet); the KL figures above are upstream's.
- **Reasoning:** GLM-5.3's template thinks by default. Maya's server closes the thinking block when a request sends `enable_thinking: false` or `reasoning_effort: none`, unlike the llama.cpp GLM slugs, where thinking can't be turned off. The server default for requests that name none is effort `max`, as on the other GLM-5.3-Flash slugs (Maya's own setup writes `high`), with Maya's own 32K reasoning budget. None of our launch knobs for effort or budgets apply.
- **Vision and DFlash2:** not in the image. Maya's DFlash2 drafter (+12% on two cards, +19% on one 3090, by upstream's measurements) has CC BY-NC-ND weights.
- **Platforms:** x86-64 only. DGX Spark (ARM) can't run it. V100s need a native build (CUDA 12).
