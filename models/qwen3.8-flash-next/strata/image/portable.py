#!/usr/bin/env python3
"""Make upstream's Strata Dockerfile build an engine that runs on other PCs.

    python3 portable.py <path/to/Dockerfile>        (edits it in place; build.sh runs it)

Upstream's Dockerfile builds the way setup.py does on a user's own machine: ggml's CPU backend
(which computes the CPU-side expert rows) and the image encoder are compiled for the CPU doing
the build (GGML_NATIVE, -march=native). That is right for a PC building its own engine and
wrong for an image other people pull: built on an AVX-512 machine (a GitHub runner may be one)
it stops with an illegal instruction on a Ryzen 5000 or a 12th-14th gen Intel. So the image is
built with -DSTRATA_PORTABLE=ON, the AVX2 baseline upstream uses for its own ready-made engines
(CMakeLists.txt: "The prebuilt release ... ggml's CPU backend for any AVX2 CPU"). Strata's own
AVX-512 kernels are per-file and still chosen at run time.

Three edits, each to text that must appear EXACTLY ONCE; anything else stops the build, because
upstream changed its build step and the edit needs a look before a release ships native code:
  1. the engine's cmake defines gain -DSTRATA_PORTABLE=ON;
  2. the image encoder's -DSTRATA_PORTABLE=OFF becomes ON;
  3. before the build trees are deleted, their CPU settings (STRATA_PORTABLE, GGML_NATIVE,
     GGML_AVX*, ...) are copied from CMakeCache.txt to EVIDENCE, which build.sh checks in the
     finished image. That works whether or not docker reused cached layers, which a check on
     the build log would not.
"""
import sys
from pathlib import Path

EVIDENCE = "/opt/club3090/strata-cpu-flags.txt"

EDITS = [
    # Anchored on the last define alone: v0.1.45 put two -D options between it and
    # -DSTRATA_ENABLE_CUDA=ON, which the old two-define anchor no longer matched.
    ('"-DSTRATA_BUILD_TESTS=OFF",',
     '"-DSTRATA_BUILD_TESTS=OFF", "-DSTRATA_PORTABLE=ON",'),
    ('"-DSTRATA_PORTABLE=OFF"',
     '"-DSTRATA_PORTABLE=ON"'),
    ("RUN rm -rf build build-vision\n",
     "RUN mkdir -p /opt/club3090 \\\n"
     "    && for t in build build-vision; do \\\n"
     "         [ -f \"$t/CMakeCache.txt\" ] || continue; \\\n"
     "         grep -E '^(STRATA_PORTABLE|GGML_NATIVE|GGML_AVX[A-Z0-9_]*|GGML_FMA|GGML_F16C|GGML_BMI2|GGML_AMX_[A-Z0-9_]*):' \\\n"
     "           \"$t/CMakeCache.txt\" | sed \"s|^|$t |\"; \\\n"
     f"       done > {EVIDENCE} \\\n"
     "    && rm -rf build build-vision\n"),
]


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    path = Path(argv[1])
    text = path.read_text(encoding="utf-8")
    bad = [old for old, _ in EDITS if text.count(old) != 1]
    for old in bad:
        print(f"[strata-image]   expected exactly once, found {text.count(old)}x: {old.strip()!r}", file=sys.stderr)
    if bad:
        print("[strata-image] upstream's Dockerfile changed where the portable build is set; "
              "update portable.py before taking this release", file=sys.stderr)
        return 1
    for old, new in EDITS:
        text = text.replace(old, new)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
