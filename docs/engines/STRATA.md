# Strata — an engine written for Qwen3.8-Flash-Next on one or two cards

**Engine id:** `strata` · **Slug prefix:** `strata/` · **Status of its slugs:** 🐣 Incubating · **Requires:** NVIDIA compute capability 7.5+, driver ≥ 580 (CUDA 13), an x86-64 CPU with AVX2, ~64 GB of host RAM for IQ3_S

## What it is

[Strata](https://github.com/Niko1221/Strata) (MIT, Niko1221) is its own C++/CUDA engine, written for one model, plus a Python server (`setup.py`) that installs, configures and serves it. It is not a llama.cpp or vLLM fork. It uses three pieces of llama.cpp as libraries, pinned in `setup.py`'s `LLAMA_CPP_COMMIT`:
- ggml's CPU backend, which computes the expert rows that run on the CPU;
- mtmd, for its image encoder;
- gguf-py, to read the GGUF files.

The scheduler, the expert cache, the CUDA kernels, the MTP draft layer and the server are its own.

Every expert is page-locked in host RAM, and the GPU keeps a cache of the hot ones, filled from a routing profile and swapped as it runs. On two cards it splits the **layers** (`--gpus 0,1`): each card caches the experts of its own layers, with one hand-off per verify window. That needs no NCCL and no P2P. It serves an OpenAI API (chat, completions, `/v1/responses`) and an Anthropic one (`/v1/messages`) on port 8080.

Its profile declares `type: strata` and `lineage.relation: new`, and the tooling knows it as engine kind `strata` (`scripts/lib/engine-kind.sh`).

## Image

Strata publishes Windows zips and a Dockerfile, but no Linux image and no Linux engine. So club-3090 builds `ghcr.io/noonghunna/strata-club3090` for each release, an image-provenance exception recorded in [ADDING_ENGINES.md](../ADDING_ENGINES.md).
- **Build:** upstream's Dockerfile at the release commit, with one change. ggml's CPU code and the image encoder are built for an AVX2 baseline (`STRATA_PORTABLE=ON`) instead of the build machine's CPU, so the image runs on other CPUs.
- **Archs:** upstream's `75;80;86;89;120` (RTX 20–50 and the A-series), plus the image encoder. H100 (sm_90) isn't built; `setup.py` compiles the engine for it at each fresh container's first start, which is untested. The `v0.1.43.1` image pinned today happens to carry sm_90 as well; the next build won't.
- **Recipe, checks, CI workflow and pin flow:** [models/qwen3.8-flash-next/strata/image/](../../models/qwen3.8-flash-next/strata/image/README.md).

The profile pins a digest, and the launchers inject it as `STRATA_IMAGE`. Export `STRATA_IMAGE` in the shell to try another build for one launch; a saved value loses to the pin.

**Bumping:** CI publishes each new release (`:<tag>`, `:sha-<commit>`), but publishing doesn't pin. To move the pin:
1. boot both slugs on the new digest through `switch.sh`;
2. run `verify-full`;
3. run `scripts/engine-pin-bump.sh strata ghcr.io/noonghunna/strata-club3090@sha256:<digest>`.

A release that renames a `setup.py` flag the entrypoint passes fails the image build, so the recipe and the entrypoint move together.

## Slugs

| Slug | Cards | Port | Notes |
|---|---|---|---|
| `strata/qwen3.8-flash-next-iq3s-dual` | 2, layer split | 20219 | the fastest offloaded Flash-Next measured on the reference rig |
| `strata/qwen3.8-flash-next-iq3s-single` | 1 | 20291 | the same install, started with `--gpu 0` |

**Weights:** both run ISTA-DASLab's GSQ-RCO IQ3_S (`ista-iq3s`, 83.6 GB in two shards).

**Data volume:** both slugs share one volume, `strata-data` under the data directory (`~/.local/share/club-3090` by default; `STRATA_DATA_DIR` overrides). It holds Strata's prepared pack, its MTP draft layer and its config.

**First start:** the slug's first start runs Strata's setup. It checks the shards, prepares the pack, and range-reads about 5 GB of MTP tensors from `Qwen/Qwen3.8-Flash-Next`, so it needs the network. On the reference rig it took about 14 minutes (image pull ~2, MTP fetch ~10, MTP pack ~2), longer than `switch.sh`'s 10-minute wait. Give the first launch `READY_TIMEOUT=1800`, or run `switch.sh` again once it times out (the container keeps going). Later starts take about 30 seconds. `SETUP_ONLY=1` runs just the setup.

**Requests and readiness:** both slugs take one request at a time. `/health` reports `loaded` before the engine has filled its expert cache. The `ready: http` line in `docker logs` is the real gate; `switch.sh`'s readiness probe (one completion) waits for it.

Measurements, with dates and settings, are in each compose's header and in [BENCHMARKS.md](../../BENCHMARKS.md) (Qwen3.8-Flash-Next, the Strata table).

## What club-3090 adds

- **One entrypoint for both composes** (`models/qwen3.8-flash-next/strata/launcher/strata-entrypoint.sh`). It replaces the image's own entrypoint, which can't take a `--gguf-dir`. Strata's setup deletes a shard whose SHA-256 doesn't match, so the entrypoint points it at symlinks on the data volume and the read-only model tree is never written. It also passes the setup flags and starts the configured install on the cards `STRATA_START_GPUS` names.
- **Runtime numbers from `/metrics`.** Strata writes its per-request lines (throughput, drafts accepted, expert-cache hits) to a log file inside the container, not to `docker logs`. `health.sh`, `verify-full` (its MTP acceptance check), `bench.sh` and `report.sh` read them from `GET /metrics` through `scripts/lib/strata_metrics.py` instead.
- **The club conventions:** the `CLUB3090_RESTART` knob, `BIND_HOST` / `ESTATE_PORT` / `ESTATE_CONTAINER` / `ESTATE_GPUS`, and the host GID plus `umask 0002` on the data volume.

## Known gaps

- **Quality:** not validated on these slugs (no 8-pack yet).
- **Reasoning defaults:** Strata reasons by default and takes no server-side effort default; the vLLM Flash-Next slugs default to `low`. A per-request thinking budget exists (`reasoning_budget_tokens`), but our tooling doesn't drive it yet: `thinking-budget.sh` refuses Strata.
- **Launch knobs:** none of ours (`SPEC_N`, `REASONING_EFFORT`, …) apply. Strata's settings live in the config its setup writes to the data volume, so `spec-sweep.sh` refuses Strata slugs.
- **Prompt-cache share:** `cache-share.sh` lists Strata but doesn't measure it. Strata's prefix-cache counters are only in its Prometheus output (`GET /metrics` with `Accept: text/plain`).
- **Platforms:** x86-64 only. Strata's CPU kernels are x86 SIMD, so DGX Spark (ARM) can't run it. A CPU without AVX2 makes setup compile Strata's older-CPU engine at the first start; that's untested.
