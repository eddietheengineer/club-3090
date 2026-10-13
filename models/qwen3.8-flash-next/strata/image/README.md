# strata-club3090 image

`ghcr.io/noonghunna/strata-club3090` is [Strata](https://github.com/Niko1221/Strata) (MIT), built by us
for each release. Strata publishes Windows zips and a Dockerfile but no Linux image and no Linux
engine, so this image is an exception to the image-provenance contract
([`docs/ADDING_ENGINES.md`](../../../../docs/ADDING_ENGINES.md)) by maintainer decision (2026-10-13).

| File | What it does |
|---|---|
| [`build.sh`](build.sh) | Resolves a release, builds it, checks the image, pushes with `--push`. CI and a maintainer run the same script. |
| [`portable.py`](portable.py) | The one change to upstream's Dockerfile (below). |
| [`../../../../.github/workflows/strata-image.yml`](../../../../.github/workflows/strata-image.yml) | Runs `build.sh --push` daily and on demand, then attests the image's provenance. |

## What we change, and why

Upstream's Dockerfile compiles the way `setup.py` does on a user's own PC. Its CPU code (ggml's CPU
backend, which computes the CPU-side expert rows, and the image encoder) is built for the CPU doing
the build. That's right for a PC that builds its own engine. It's wrong for an image other people
pull: built on an AVX-512 machine, it stops with an illegal instruction on a CPU without AVX-512,
such as a Ryzen 5000 or a 12th–14th gen Intel. GitHub's runners vary in CPU.

`portable.py` adds `-DSTRATA_PORTABLE=ON` to the engine build and turns the image encoder's
`-DSTRATA_PORTABLE=OFF` on. That gives ggml's CPU code the AVX2 baseline upstream uses for its own
ready-made engines. Strata's own AVX-512 kernels are compiled per file and still chosen at run time,
but ggml's AVX-512 paths are off. So:

- **The built engine needs an AVX2 CPU.** On a CPU without AVX2, `setup.py`'s reuse test rejects it
  and compiles its older-CPU engine at the first start, using the toolchain the image carries. That
  follows from reading `setup.py`; it hasn't been tested.
- **Decode on an AVX-512 CPU may be a little slower** than an engine compiled on that PC. Not measured.

`portable.py` also copies each build tree's CPU settings out of `CMakeCache.txt` into
`/opt/club3090/strata-cpu-flags.txt` before the trees are deleted, so the check below reads what the
build actually used. Each edit matches text that must occur exactly once. If upstream reworks its
build step, the edit refuses and the build stops; it never ships a native build without saying so.

Everything else is upstream's: the Dockerfile at the release's commit (CUDA 13.0 devel base, so the
host needs an NVIDIA driver ≥ 580) and the image encoder (`BUILD_VISION=1`).

**GPU archs: upstream's default plus `90`.** Upstream builds `75;80;86;89;120` (RTX 20 / 30 / 40 / 50
and the A-series). We add `90` because H100 is a club hardware class. A card whose arch isn't in the
image still starts, but `setup.py` compiles the engine for it at the first start of every fresh
container (the engine lives in the image, not on `/data`). That follows from `setup.py`'s reuse test; it
hasn't been tested. Other cards:

| Card | Arch | |
|---|---|---|
| B200 / GB200 | `100` | not built (no club hardware class): compiles at each fresh container's first start |
| DGX Spark (GB10) | `121` | **can't run**: ARM CPU, while the image is x86-64 and Strata's CPU kernels are x86 SIMD |
| P100 / V100 | `60` / `70` | not built: CUDA 13 dropped them; upstream's experimental CUDA 12 build isn't in this image |

## What a build checks

`build.sh` stops at the first failure, before anything is pushed:

| Check | Catches |
|---|---|
| The release tag resolves to a commit, and the build uses that commit | a tag moved after we built it |
| `<image>:<tag>` is not already published. Only "not found" counts as unpublished | re-pushing a tag (any other registry error stops the run) |
| `portable.py` applies | upstream reworking its build step |
| Both build trees: `STRATA_PORTABLE` and `GGML_AVX2` on; `GGML_NATIVE`, AVX-512, AVX-VNNI and AMX off | CPU code native to the build machine |
| `engine/BUILD.json` names the release, our archs and vision | a build that didn't take our arguments |
| BUILD.json's source hashes and the binary's version match the tree, the way `setup.py` compares them | a first start that compiles the engine again (15+ minutes, natively) |
| Every library resolves except the host driver's (`libcuda`, `libnvidia-*`) | a library missing from the image |
| `setup.py --help` still has every flag our compose recipe passes | a release that renamed or dropped one |

None of these need a GPU. Whether the engine actually serves is the rig's job (below).

## Running it

```bash
bash models/qwen3.8-flash-next/strata/image/build.sh                     # newest release: build + check, no push
bash models/qwen3.8-flash-next/strata/image/build.sh --tag v0.1.43.1     # one release
bash models/qwen3.8-flash-next/strata/image/build.sh --tag v0.1.43.1 --verify <image>   # checks only
```

`--push` publishes `:<tag>` and `:sha-<commit7>` and prints the digest. `--force` rebuilds a tag that
is already published, giving it a new digest. `CUDA_ARCHITECTURES`, `BUILD_VISION` and
`STRATA_IMAGE` override the defaults (a narrower build is for local use, not for publishing).

CI: the workflow builds the newest release once a day, and on demand from the Actions tab
(`Run workflow`, with an optional tag). When two releases land on the same day, only the newer one is
built, which is fine because we only need the release we pin. A failed run emails whoever last edited
the schedule.

## From a new image to a pin

A published image is not a pin. To move the strata engine profile to a new release:

1. Take the digest from the run's summary (or `docker buildx imagetools inspect ghcr.io/noonghunna/strata-club3090:<tag>`).
2. Boot a strata slug on the rig with that digest, then run `verify-full`. On the first start, the engine
   log should say the engine is reused (`engine already built for this PC`), with no cmake run.
3. Bump with `scripts/engine-pin-bump.sh strata ghcr.io/noonghunna/strata-club3090@sha256:<digest>` and open a PR.

## Maintainer notes

- **The package must be public**, or no user can pull it. A new GHCR package starts private: after the first
  push, set it to public once under the package's settings, then check from a machine with no login:
  `DOCKER_CONFIG=$(mktemp -d) docker buildx imagetools inspect ghcr.io/noonghunna/strata-club3090:<tag>`.
- **Never delete a pinned digest.** Old tags can be pruned, but any digest an engine profile, a release or a
  user's saved setting may still name has to stay pullable.
- **When `portable.py` refuses**, read upstream's new Dockerfile, move the edits to the new text, and run
  the build by hand once before letting CI publish.
- **When the flag check fails**, `strata-entrypoint.sh` in the compose recipe needs the new spelling first;
  update both together.
