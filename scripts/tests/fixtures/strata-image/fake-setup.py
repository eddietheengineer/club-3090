"""A stand-in for Strata's setup.py with just what the Dockerfile's build step calls.

cmake_build calls the module-global run() the way the real one does (setup.py v0.1.43.1), so a
wrapper that replaces setup.run is exercised exactly as in a real build. Each run() call is logged
to $FAKE_RUN_LOG; FAKE_NO_J=1 leaves -j out of the build command, as a setup.py that stopped
passing it would.
"""
import json, os
from pathlib import Path

ROOT = Path.cwd()
EXE, VEXE = "strata", "strata-vision"
ENGINE_SOURCES, VISION_SOURCES = ("src",), ("tools/vision",)


def run(cmd, check=True):
    with open(os.environ["FAKE_RUN_LOG"], "a", encoding="utf-8") as f:
        f.write(json.dumps([str(c) for c in cmd]) + "\n")

    class R:
        returncode = 0
    return R()


def get_llama_cpp():
    return ROOT / "third_party" / "llama.cpp"


def find_nvcc():
    return "/usr/local/cuda/bin/nvcc", (13, 0)


def cmake_build(src, bdir, target, defs, vcvars, bat_name):
    conf = ["cmake", "-G", "Ninja", "-S", str(src), "-B", str(bdir), *defs]
    build = ["cmake", "--build", str(bdir), "--target", target]
    if os.environ.get("FAKE_NO_J") != "1":
        build += ["-j", str(max(2, (os.cpu_count() or 4) // 2))]
    run(conf)
    if run(build, check=False).returncode != 0:
        run(build)
    out = Path(bdir) / ("bin" if target == "strata-vision" else "")
    out.mkdir(parents=True, exist_ok=True)
    (out / (VEXE if target == "strata-vision" else EXE)).write_text("binary\n", encoding="utf-8")


def source_version():
    return "0.1.43.1"


def source_hash(paths):
    return "hash"
