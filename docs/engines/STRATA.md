# Strata — an engine written for Qwen3.8-Flash-Next on one or two cards

**Engine id:** `strata` · **Slug prefix:** `strata/` · **Status of its slugs:** 🐣 Incubating · **Requires:** NVIDIA compute capability 7.5+, driver ≥ 580 (CUDA 13), an x86-64 CPU with AVX2, ~86 GB of host RAM for IQ3_S when the model disk is rotational (setup keeps the 28.8 GB n-gram table in RAM; less on an SSD)

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
- **Archs:** upstream's `75;80;86;89;120` (RTX 20–50 and the A-series), plus the image encoder. H100 (sm_90) isn't built; `setup.py` compiles the engine for it at each fresh container's first start, which is untested. The `v0.1.43.1` image pinned on 2026-10-13 carried sm_90 as well; `v0.1.44.1` and the pinned `v0.1.45` don't.
- **Recipe, checks, publishing and pin flow:** [models/qwen3.8-flash-next/strata/image/](../../models/qwen3.8-flash-next/strata/image/README.md).

The profile pins a digest, and the launchers inject it as `STRATA_IMAGE`. Export `STRATA_IMAGE` in the shell to try another build for one launch; a saved value loses to the pin.

**Bumping:** the maintainer publishes a release from the rig with `build.sh --tag <vX.Y.Z> --push` (`:<tag>`, `:sha-<commit>`), but publishing doesn't pin. To move the pin:
1. boot a slug of each model family (ISTA and Swift) on the new digest through `switch.sh`;
2. run `verify-full`;
3. run `scripts/engine-pin-bump.sh strata ghcr.io/noonghunna/strata-club3090@sha256:<digest>`.

A release that renames a `setup.py` flag the entrypoint passes fails the image build, so the recipe and the entrypoint move together.

## Slugs

| Slug | Cards | Port | Notes |
|---|---|---|---|
| `strata/qwen3.8-flash-next-iq3s-dual` | 2, layer split | 8018 | the fastest offloaded Flash-Next measured on the reference rig |
| `strata/qwen3.8-flash-next-iq3s-single` | 1 | 8019 | the same install, started with `--gpu 0` |
| `strata/qwen3.8-flash-next-swift15-abliterated-iq3s-dual` | 2, layer split | 8024 | SC117's abliterated Swift 1.5 |
| `strata/qwen3.8-flash-next-swift15-abliterated-iq3s-single` | 1 | 8025 | the same install, started with `--gpu 0` |
| `strata/qwen3.8-flash-next-swift15-abliterated-iq3s-multi4` | 4, layer split | 8046 | the same install on `--gpus 0,1,2,3`; never booted here (two cards): community-validated |

**Weights:**
- The first two run ISTA-DASLab's GSQ-RCO IQ3_S of the original model (`ista-iq3s`, 83.6 GB in two shards).
- The `swift15-abliterated` pair runs SC117's abliterated GSQ-RCO IQ3_S of UkisAI's Swift 1.5 (`sc117-swift15-abliterated-iq3s`, 83.55 GB in two shards, pinned to revision `2b89cf3f`). Swift 1.5 is a fine-tune of Qwen3.8-Flash-Next that thinks much shorter. SC117 replaced its 144 residual-writer tensors with ones from orcarouter's abliterated release, which removes the refusal direction. Its README says it has no reliable built-in guardrails, so put your own moderation in front of anything user-facing. It is under the Swift Open License 1.0 (commercial use is free only below US$1M annual revenue) as well as the Qwen licence. Strata serves it as its `swift` model family.

**Data volume:** all five slugs share one volume, `strata-data` under the data directory (`~/.local/share/club-3090` by default; `STRATA_DATA_DIR` overrides). It holds Strata's MTP draft layer, which every slug shares, and one links folder, config and prepared pack per model family (`strata-iq3_s` for ISTA, `strata-swift-iq3_s` for Swift).

**First start:** the first start of each model family runs Strata's setup. It checks the shards, prepares that family's pack, and, unless the volume already has it, range-reads about 5 GB of MTP tensors from `Qwen/Qwen3.8-Flash-Next`, so it needs the network. Swift 1.5 ships no draft layer of its own, so its slugs use the same one. On the reference rig it took about 14 minutes (image pull ~2, MTP fetch ~10, MTP pack ~2), longer than `switch.sh`'s 10-minute wait. Give the first launch `READY_TIMEOUT=1800`, or run `switch.sh` again once it times out (the container keeps going). Later starts take about 30 seconds. `SETUP_ONLY=1` runs just the setup.

**Requests and readiness:** every Strata slug takes one request at a time. `/health` reports `loaded` before the engine has filled its expert cache. The `ready: http` line in `docker logs` is the real gate; `switch.sh`'s readiness probe (one completion) waits for it.

Measurements, with dates and settings, are in each compose's header and in [BENCHMARKS.md](../../BENCHMARKS.md) (Qwen3.8-Flash-Next, the Strata table).

## What club-3090 adds

- **One entrypoint for every compose** (`models/qwen3.8-flash-next/strata/launcher/strata-entrypoint.sh`). It replaces the image's own entrypoint, which can't take a `--gguf-dir`. Strata's setup deletes a shard whose SHA-256 doesn't match, so the entrypoint points it at symlinks on the data volume and the read-only model tree is never written. Each link takes the name setup expects for the model family, which is how SC117's `-abliterated` files load as Swift 1.5. The compose passes the family as the entrypoint's one argument (`qwen` when absent, or `swift`), not as a setting, so no saved value can point a slug at the other model's files. The entrypoint also passes the setup flags and starts the configured install on the cards `STRATA_START_GPUS` names.
- **Runtime numbers from `/metrics`.** Strata writes its per-request lines (throughput, drafts accepted, expert-cache hits) to a log file inside the container, not to `docker logs`. `health.sh`, `verify-full` (its MTP acceptance check), `bench.sh` and `report.sh` read them from `GET /metrics` through `scripts/lib/strata_metrics.py` instead.
- **Launch settings, written into Strata's own config at every boot** (`launcher/strata_config.py`). Strata reads these from the config its setup writes to the data volume, and setup writes none of them, so before this a setting only took effect if you edited the JSON by hand. The entrypoint keeps setup's output as `config/strata-<family>.setup.json` and rebuilds the live config from it plus your settings each time, so a setting you remove is gone at the next boot. A bad value stops the boot with the reason. `REASONING_EFFORT`, `ENABLE_THINKING` and `SPEC_N` are catalogued, so `bash scripts/switch.sh --set <slug> REASONING_EFFORT=low` saves them for one slug; `--set` refuses the others, so save those with `bash scripts/settings.sh set TEMP=0.7` (they apply to every slug that reads them) or give them as a shell prefix.

  | Setting | Strata config | Values | Unset |
  |---|---|---|---|
  | `REASONING_EFFORT` | `reasoning_effort` | `none`, `low`, `medium`, `high` (`xhigh` and `max` mean `high`, the template's xhigh) | the template's default, xhigh |
  | `ENABLE_THINKING` | `reasoning_effort: none` when `false` | `true`, `false`; `false` wins over `REASONING_EFFORT` | thinking on |
  | `THINKING_BUDGET` | `reasoning_budget_tokens` | tokens, `0` = no budget; one cap for every request (Strata has no per-effort budgets) | no cap |
  | `SPEC_N` | `--spec N` in the engine args | `1`–`8`: the MTP drafter's verify window; the drafter can't be turned off from here | `4` (setup's) |
  | `TEMP`, `TOP_P`, `TOP_K`, `MIN_P`, `PRESENCE_PENALTY`, `REPEAT_PENALTY` | `sampling.temperature`, `.top_p`, `.top_k`, `.min_p`, `.presence_penalty`, `.repetition_penalty` | ≥ 0 / 0–1 / 1–64 / 0–1 / ≥ 0 / > 0 | the model card's (see Known gaps) |
  | `CONTEXT`, `KV` | setup's `--max-context` and `--kv` | a context ≥ 4096; `fp16`, `int8`, `q4_0`, `k8v4` | 131072 / setup's choice (int8 here) |

  `CONTEXT` and `KV` size the KV cache and the expert cache, so setup owns them: a value that differs from what setup was given runs setup again at the next boot (it says why). A request's own fields always win over these defaults, and so do the Chat settings saved from Strata's web page: they fill effort and sampling before the config does. `MAX_TOKENS` doesn't apply: Strata takes a default output cap only from those saved Chat settings (`max_tokens` in its run config is the vision encoder's), so a request with no `max_tokens` runs to the end of the context. Until 2026-10-17 the launcher wrote it anyway, to no effect.
- **The club conventions:** the `CLUB3090_RESTART` knob, `BIND_HOST` / `ESTATE_PORT` / `ESTATE_CONTAINER` / `ESTATE_GPUS`, and the host GID plus `umask 0002` on the data volume.

## Known gaps

- **Quality:** not validated on these slugs (no 8-pack yet). For the abliterated Swift slugs, SC117 published measurements for its IQ2_XS tier only: decode about 2% slower than upstream Swift, and MTP draft acceptance 62.5% against 66.8% with the base model's draft layer.
- **Reasoning and sampling defaults:** with no settings, a request that names no effort runs at the template's default, `xhigh` (`high` and `max` also map to `xhigh`). That is the checkpoint's own chat-template default (`reasoning_effort|default('xhigh')`), and the `bucko-vllm` slugs keep it too: they also run at xhigh, with a 16,384-token default thinking budget on top. Only the Qwen3.8-27B vLLM and SGLang composes default to `low`. `REASONING_EFFORT` / `ENABLE_THINKING` change that server-side (above). Since v0.1.45, a sampler field a request leaves out comes from the model card unless the `TEMP` … `REPEAT_PENALTY` settings fill it: thinking requests get temperature 1.0, top_p 0.95, top_k 20; thinking-off requests get 0.7, 0.8, 20 and presence_penalty 1.5. Before v0.1.45 a request with no sampler decoded greedy, and only `temperature: 0` does now. A field the request sends always wins; for the 8-pack, [RUN_EVALS.md](../RUN_EVALS.md) has the commands. `THINKING_BUDGET` sets one thinking cap for every request; `thinking-budget.sh` (per-effort budgets) still refuses Strata.
- **`spec-sweep.sh`** still refuses Strata slugs, although `SPEC_N` now applies: a sweep would need it to reboot per depth through the setting, which it doesn't do for Strata yet.
- **Prompt-cache share:** `cache-share.sh` lists Strata but doesn't measure it. Strata's prefix-cache counters are only in its Prometheus output (`GET /metrics` with `Accept: text/plain`).
- **Platforms:** x86-64 only. Strata's CPU kernels are x86 SIMD, so DGX Spark (ARM) can't run it. A CPU without AVX2 makes setup compile Strata's older-CPU engine at the first start; that's untested.
