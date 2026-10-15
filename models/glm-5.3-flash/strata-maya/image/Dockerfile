# syntax=docker/dockerfile:1
#
# ghcr.io/noonghunna/strata-maya-club3090: Project Maya (github.com/mw00/project-maya, MIT), a fork of
# Strata for GLM-5.3-Flash, built by club-3090 from one release. Upstream ships no Dockerfile, no
# image and no Linux engine (its setup compiles on the user's PC), so this file is ours. build.sh
# fetches the release's commit into the build context and runs it; see README.md.
#
# What it builds, the way maya.py's compile_engine does, with two differences:
#   - STRATA_PORTABLE=ON: ggml's CPU code for an AVX2 baseline instead of the build machine's CPU
#     (upstream's CMake option, which maya.py passes only for its HIP build);
#   - CUDA archs from CUDA_ARCHITECTURES (a fat binary) instead of the user's own cards.
# Text only: the vision encoder and the DFlash2 drafter are not built or fetched.

ARG CUDA_VERSION=13.0.0

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates cmake curl git ninja-build python3 unzip \
    && rm -rf /var/lib/apt/lists/*

ARG CUDA_ARCHITECTURES="75;80;86;89;120"
# llama.cpp's source at the commit setup.py pins (LLAMA_CPP_COMMIT): ggml's CPU backend comes from it
ARG LLAMA_CPP_COMMIT
# empty: half the CPU threads, as maya.py does (nvcc takes 2-4 GB per job on the big kernels)
ARG JOBS=""

COPY . /src
RUN test -n "$LLAMA_CPP_COMMIT" \
    && curl -fsSL -o /tmp/llama.zip "https://github.com/ggml-org/llama.cpp/archive/${LLAMA_CPP_COMMIT}.zip" \
    && unzip -q /tmp/llama.zip -d /tmp \
    && mv "/tmp/llama.cpp-${LLAMA_CPP_COMMIT}" /llama.cpp \
    && rm /tmp/llama.zip

RUN cmake -S /src -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DSTRATA_ENABLE_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES}" \
        -DSTRATA_NATIVE_EXPERTS=ON -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON \
        -DSTRATA_GGML_DIR=/llama.cpp
RUN jobs="${JOBS:-$(( $(nproc) / 2 ))}"; [ "$jobs" -ge 1 ] || jobs=1; \
    cmake --build /build --target strata -j "$jobs"
# the CPU settings and archs the tree was configured with, read by build.sh's checks
RUN mkdir -p /out && cp /build/strata /out/strata \
    && grep -E '^(STRATA_PORTABLE|GGML_NATIVE|GGML_AVX[A-Z0-9_]*|GGML_FMA|GGML_F16C|GGML_BMI2|GGML_AMX_[A-Z0-9_]*):' \
         /build/CMakeCache.txt | sed 's/^/build /' > /out/maya-cpu-flags.txt \
    && sed -n 's/^CMAKE_CUDA_ARCHITECTURES:[A-Z]*=//p' /build/CMakeCache.txt > /out/cuda-architectures.txt

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 \
    MAYA_UPDATE_CHECK=0
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# The release's own files, less what only the setup, the tests or the HIP build use. The server
# (serve/server.py) and the pack builder (tools/iq_pack.py) run from this tree.
COPY --from=build /src /opt/maya
# (data/glm5-synth.gguf, 12 MB, stays: build.sh packs it to check the pack builder works)
RUN rm -rf /opt/maya/.git /opt/maya/tests /opt/maya/bench /opt/maya/ref /opt/maya/third_party/wheels \
           /opt/maya/data/glm5-*-dumps*
# llama.cpp's gguf-py, where setup.py puts it (tools/_paths.py looks there): the pack builder reads the
# tokenizer with it
COPY --from=build /llama.cpp/gguf-py /opt/maya/third_party/llama.cpp/gguf-py
# setup.py's PY_PACKAGES, less cmake / ninja (build tools); the versions pip took are recorded
RUN python3 -m venv /opt/maya/.venv \
    && /opt/maya/.venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/maya/.venv/bin/pip install --no-cache-dir numpy jinja2 regex pyyaml tqdm requests pillow psutil \
    && mkdir -p /opt/club3090 \
    && /opt/maya/.venv/bin/pip freeze > /opt/club3090/maya-pip-freeze.txt
COPY --from=build /out/strata /opt/maya/build/strata
COPY --from=build /out/maya-cpu-flags.txt /out/cuda-architectures.txt /opt/club3090/

WORKDIR /opt/maya
# No entrypoint of our own in the image: the composes mount the launcher
# (models/glm-5.3-flash/strata-maya/launcher/) and run it.
CMD ["/opt/maya/.venv/bin/python", "/opt/maya/serve/server.py", "--help"]
