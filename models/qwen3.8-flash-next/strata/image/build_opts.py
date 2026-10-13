#!/usr/bin/env python3
"""Opt-in build speedups for upstream's Strata Dockerfile, for builds on a maintainer's rig.

    python3 build_opts.py <path/to/Dockerfile> [--jobs N] [--ccache]   (edits it in place; build.sh runs it)

Nothing here changes what is compiled, only how fast. The published image (CI) is built without
these, so its recipe stays upstream's Dockerfile plus portable.py.

--jobs N   setup.py's cmake_build passes `-j max(2, cpu_count // 2)` on the command line, which
           CMAKE_BUILD_PARALLEL_LEVEL can't override: 16 jobs on a 32-thread rig. The build step
           wraps setup.run so every `cmake --build` gets `-j N` instead, prints each one, and
           fails if no build command took it (setup.py stopped building that way).
--ccache   Compiles go through ccache (C, C++ and CUDA, via CMAKE_<LANG>_COMPILER_LAUNCHER, which
           ggml's own ccache detection then leaves alone), with the cache in a BuildKit cache
           mount that outlives the build. The build trees sit at the same paths every build, so a
           later build reuses every object whose source didn't change: llama.cpp is pinned, and
           it is most of the compile. The image gains the ccache package, so build.sh refuses to
           publish one; the build step prints ccache's stats and fails if nothing went through it.

Like portable.py, each edit replaces text that must appear EXACTLY ONCE; anything else stops the
build, because upstream changed its build step.
"""
import argparse
import sys
from pathlib import Path

CACHE_ID = "strata-club3090-ccache"
CACHE_DIR = "/ccache"

APT_ANCHOR = "build-essential ca-certificates curl git"
RUN_ANCHOR = "RUN .venv/bin/python - <<'PYEOF'\n"
IMPORT_ANCHOR = "\nimport setup\n"
END_ANCHOR = "\nPYEOF\n"


def prelude(jobs, ccache):
    """Python for the top of the build step, after `import setup`."""
    lines = []
    if jobs:
        lines += [
            "# club-3090 build_opts.py --jobs: every cmake --build runs with this many jobs",
            f"_club3090_jobs, _club3090_jobs_used = {str(jobs)!r}, []",
            "_club3090_run = setup.run",
            "def _club3090_run_jobs(cmd, *a, **k):",
            "    cmd = list(cmd)",
            "    if '--build' in cmd and '-j' in cmd:",
            "        cmd[cmd.index('-j') + 1] = _club3090_jobs",
            "        _club3090_jobs_used.append(cmd)",
            "        print(f'[club3090] cmake --build -j {_club3090_jobs}: {cmd[cmd.index(\"--build\") + 1]}', flush=True)",
            "    return _club3090_run(cmd, *a, **k)",
            "setup.run = _club3090_run_jobs",
        ]
    if ccache:
        lines += [
            "# club-3090 build_opts.py --ccache: this build's stats only",
            "import subprocess as _club3090_sp",
            "_club3090_sp.run(['ccache', '--zero-stats'], check=True, stdout=_club3090_sp.DEVNULL)",
        ]
    return "\n".join(lines) + "\n"


def epilogue(jobs, ccache):
    """Python for the end of the build step: prove each option took effect."""
    lines = []
    if jobs:
        lines += [
            "if not _club3090_jobs_used:",
            "    raise SystemExit('[club3090] --jobs: no cmake --build command took -j; setup.py changed how it builds')",
        ]
    if ccache:
        lines += [
            "_club3090_sp.run(['ccache', '--show-stats'], check=True)",
            "_club3090_stats = dict(l.split('\\t', 1) for l in _club3090_sp.run(",
            "    ['ccache', '--print-stats'], check=True, capture_output=True, text=True).stdout.splitlines() if '\\t' in l)",
            "_club3090_n = lambda k: int(_club3090_stats.get(k, '0'))",
            "_club3090_hits = _club3090_n('direct_cache_hit') + _club3090_n('preprocessed_cache_hit')",
            "_club3090_miss = _club3090_n('cache_miss')",
            "print(f'[club3090] ccache: {_club3090_hits} hits, {_club3090_miss} misses, '",
            "      f\"{_club3090_n('unsupported_compiler_option')} unsupported\", flush=True)",
            "if _club3090_hits + _club3090_miss == 0:",
            "    raise SystemExit('[club3090] --ccache: no compile went through ccache')",
        ]
    return "\n".join(lines) + "\n"


def edits(jobs, ccache):
    out = [(IMPORT_ANCHOR, IMPORT_ANCHOR + prelude(jobs, ccache)),
           (END_ANCHOR, "\n" + epilogue(jobs, ccache).rstrip("\n") + END_ANCHOR)]
    if ccache:
        env = (f"CCACHE_DIR={CACHE_DIR} CCACHE_MAXSIZE=20G CMAKE_C_COMPILER_LAUNCHER=ccache "
               "CMAKE_CXX_COMPILER_LAUNCHER=ccache CMAKE_CUDA_COMPILER_LAUNCHER=ccache")
        out += [(APT_ANCHOR, "build-essential ca-certificates ccache curl git"),
                (RUN_ANCHOR, f"RUN --mount=type=cache,id={CACHE_ID},target={CACHE_DIR} {env} "
                             f"{RUN_ANCHOR[len('RUN '):]}")]
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("dockerfile", type=Path)
    ap.add_argument("--jobs", type=int)
    ap.add_argument("--ccache", action="store_true")
    a = ap.parse_args(argv[1:])
    if a.jobs is not None and a.jobs < 1:
        ap.error("--jobs must be a positive number")
    if not a.jobs and not a.ccache:
        ap.error("nothing to do: pass --jobs N and/or --ccache")
    text = a.dockerfile.read_text(encoding="utf-8")
    todo = edits(a.jobs, a.ccache)
    bad = [old for old, _ in todo if text.count(old) != 1]
    for old in bad:
        print(f"[strata-image]   expected exactly once, found {text.count(old)}x: {old.strip()!r}", file=sys.stderr)
    if bad:
        print("[strata-image] upstream's Dockerfile changed where the build options go; "
              "update build_opts.py before using them on this release", file=sys.stderr)
        return 1
    for old, new in todo:
        text = text.replace(old, new)
    tmp = a.dockerfile.with_name(a.dockerfile.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(a.dockerfile)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
