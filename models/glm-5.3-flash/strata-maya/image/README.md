# strata-maya-club3090 image

`ghcr.io/noonghunna/strata-maya-club3090` is [Project Maya](https://github.com/mw00/project-maya) (MIT),
a fork of [Strata](https://github.com/Niko1221/Strata) for GLM-5.3-Flash, built by us for each release.
Maya publishes no image, no Dockerfile and no Linux engine (its `maya.sh` compiles on the user's PC),
so this image is an exception to the image-provenance contract
([`docs/ADDING_ENGINES.md`](../../../../docs/ADDING_ENGINES.md)) by maintainer decision (2026-10-15).

| File | What it does |
|---|---|
| [`Dockerfile`](Dockerfile) | Ours: compiles the engine the way `maya.py` does and installs the server's Python packages. |
| [`build.sh`](build.sh) | Resolves a release, builds it, checks the image, pushes with `--push`. CI and a maintainer run the same script. |
| [`../../../../.github/workflows/strata-maya-image.yml`](../../../../.github/workflows/strata-maya-image.yml) | Runs `build.sh --push` daily and on demand, then attests the image's provenance. |

## What the image is

Two stages on NVIDIA's CUDA 13.0 images (so the host needs a driver ≥ 580):

1. **Build** (`-devel`): the release's tree at its commit, llama.cpp's source at the commit `setup.py`
   pins (`LLAMA_CPP_COMMIT`; ggml's CPU backend computes the CPU-side experts), then the `strata`
   target with the flags `maya.py`'s `compile_engine` passes, plus two of ours:
   - **`-DSTRATA_PORTABLE=ON`**: ggml's CPU code for an AVX2 baseline. Without it the CMake sets
     `GGML_NATIVE=ON`, which builds for the build machine's CPU: right for a PC that compiles its own
     engine, wrong for an image (built on an AVX-512 runner, it would stop with an illegal
     instruction on a Ryzen 5000). It is upstream's own option; `maya.py` passes it only for its HIP
     build. Maya's own AVX-512 kernels are compiled per file and chosen at run time either way.
   - **`CMAKE_CUDA_ARCHITECTURES=75;80;86;89;120`** (RTX 20 / 30 / 40 / 50 and the A-series) instead of the
     user's own cards: a fat binary, one cubin per arch.
2. **Runtime** (`-runtime`, which carries cudart and cuBLAS): the release's files in `/opt/maya`
   (less `.git`, tests, benches and test dumps), llama.cpp's `gguf-py` in `third_party/llama.cpp/` where `setup.py` puts it (the pack builder reads the tokenizer with it), the engine at `/opt/maya/build/strata`, and a
   `.venv` with `setup.py`'s `PY_PACKAGES` less the build tools (the versions pip took are in
   `/opt/club3090/maya-pip-freeze.txt`). `MAYA_UPDATE_CHECK=0`: the dashboard's self-update does a
   `git` fast-forward, which an image can't do.

**Text only.** The vision encoder and the DFlash2 drafter are not built or fetched (the drafter's
weights are CC BY-NC-ND). The image has no entrypoint of its own: the composes mount our launcher
(`models/glm-5.3-flash/strata-maya/launcher/`), which builds Maya's pack on the data volume, writes the
config and starts `serve/server.py`. Maya's own setup (`maya.sh`) is not used in the image.

| Card | Arch | |
|---|---|---|
| H100 | `90` | not built (Maya's CMake refuses only archs below 75, so a build with `CUDA_ARCHITECTURES` adding 90 should work; untested) |
| B200 / GB200 | `100` | not built (no club hardware class) |
| DGX Spark (GB10) | `121` | **can't run**: ARM CPU, while the image is x86-64 and the CPU kernels are x86 SIMD |
| P100 / V100 | `60` / `70` | not built: CUDA 13 dropped them. Maya is developed on V100s; run `maya.sh` natively with CUDA 12 there |

Not measured: decode on an AVX-512 CPU against a natively compiled engine (the Strata image notes the
same open question).

## What a build checks

`build.sh` stops at the first failure, before anything is pushed:

| Check | Catches |
|---|---|
| tag → commit, built at that commit; VERSION file = the tag | a tag moved after the fact; a release whose files don't match its tag |
| `setup.py`'s llama.cpp pin = `CMakeLists.txt`'s `GIT_TAG` | upstream's two pins disagreeing (we build from `setup.py`'s, as `maya.py` does) |
| skip when `:<tag>` is already published (only "not found" = unpublished) | re-pushing a tag over an image users may have pinned |
| `/opt/club3090/maya-cpu-flags.txt`: `STRATA_PORTABLE` on, `GGML_NATIVE` off, `GGML_AVX2` on, no AVX-512 / VNNI / AMX | a native build slipping through (read from `CMakeCache.txt`, not the build log) |
| `/opt/club3090/cuda-architectures.txt` = the archs asked for | a build for the wrong cards |
| `ldd` on the engine: everything resolves except `libcuda` / `libnvidia-*` | a runtime library missing from the runtime stage |
| `serve/server.py --help` and `tools/iq_pack.py --help` still offer every flag the launcher passes; the expert profile is there | a release renaming a flag that every launch depends on |
| llama.cpp's `gguf-py` imports the way Maya's tools look for it, and `iq_pack.py` indexes the release's 12 MB synthetic GLM-5 model (`data/glm5-synth.gguf`; it carries no tokenizer, so the check wants the index and dense weights) | a pack builder that can't run in the image (the first local build lacked `gguf-py` and failed exactly there) |

None needs a GPU, so they run on CI. **A published image is not a pin.** The `strata-maya` engine
profile moves to a new digest only after a rig boot and verify-full (`engine-pin-bump.sh`).

## Run it by hand

```bash
bash models/glm-5.3-flash/strata-maya/image/build.sh                       # newest release: build + check
bash models/glm-5.3-flash/strata-maya/image/build.sh --tag v1.1.11 --push  # what CI runs (plus --jobs 4)
bash models/glm-5.3-flash/strata-maya/image/build.sh --tag v1.1.11 --verify ghcr.io/noonghunna/strata-maya-club3090:v1.1.11
CUDA_ARCHITECTURES=86 STRATA_MAYA_IMAGE=strata-maya-local \
  bash models/glm-5.3-flash/strata-maya/image/build.sh --tag v1.1.11 --jobs 16 --force   # a quick local build for one card
```

A local image name needs `--force`: the "already published?" probe can't tell an unpublished local
name from a registry error. **The published image stays CI-built** (provenance attestation); local
builds are for testing.
