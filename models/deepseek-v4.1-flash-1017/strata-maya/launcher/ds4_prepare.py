"""Prepare DeepSeek-V4.1-Flash-1017 for Project Maya's maya-ds4 engine on the data volume, for ds4-entrypoint.sh.

The weights are mounted read-only at /gguf (ISTA-DASLab's GSQ-RCO GGUF: four backbone shards and the shared Engram
file beside them) and the DSpark drafter at /dspark (peasantsmith's dspark-xs2: a .bin and its .json). Maya's
tools/ds4/pack_gguf.py writes its pack (an index of those files, no weights copied) wherever --out says, and the pack
names the model folder it indexes (ds4.txt model_dir), so the pack lives on /data and the files stay where they are:

    /data/<tag>/pack/            tools/ds4/pack_gguf.py's output + sources.json; expert-profile.bin (the engine's
                                 routing counts, seeded from the image's data/expert-profile-ds4.bin, then its own)
    /data/<tag>/verified.json    the files' sizes and times when their SHA-256 matched
    /data/<tag>/maya-ds4.json    the config serve/server.py starts from
    /data/<tag>/maya-ds4.log     the engine's log

Steps, each skipped when already done: check the files' SHA-256 against WEIGHTS (Maya's own tables don't list ISTA's
quant; minutes, once, again only when a file's size or time changes); build the pack (seconds; again when a file
changed after it was built); seed the expert profile; fill the DSpark geometry the GGUF lacks (fix_dspark); write the
config. Python stdlib only, plus the image's /opt/maya."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import ds4_settings                                   # beside this file: club-3090's launch settings

MAYA = Path("/opt/maya")
# Every file a tag reads, with its SHA-256 (the Hugging Face LFS oid at the pinned revision; the .json is a plain git
# file: its SHA-256 measured from that revision's copy). Folder: "gguf" = /gguf, "dspark" = /dspark.
WEIGHTS = {
    "ista-iq2-xxs": {
        "gguf": {   # ISTA-DASLab/DeepSeek-V4.1-Flash-1017-GSQ-RCO-GGUF @85d6710f (files unchanged since cb02422c)
            "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00001-of-00004.gguf":
                "d46efb67ccffd8fb5d7f18b423896381b9e06d8491e161c370ddf3b05b07e050",
            "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00002-of-00004.gguf":
                "cec1b2c3da429dc768b8bb9bc4dc4403d81f74d34db660a6a34ee3e555bf2c70",
            "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00003-of-00004.gguf":
                "9d9c2140fcb134a0b9a74dedd0e5167e68077af6d08ce7f856bce112f0a35dd3",
            "DeepSeek-V4.1-Flash-1017-GSQ-RCO-IQ2_XXS-00004-of-00004.gguf":
                "9b790a2297ed3cdede379fc984f4a52bb95f3b23724c797af11d1fa6a69db059",
            "DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf":
                "eb19f30d368d393784e1fc54fdfaffc427ebb2110bf3762fdf5a8fbb9a2d740a",
        },
        "dspark": {   # peasantsmith/DeepSeek-V4.1-Flash-1017-Maya-GGUF @d1fc0100, dspark/
            "dspark-xs2.bin": "8dfe21082a6cb320f334fddb454630c241c6d44e0463eef4f8b0b07334511779",
            "dspark-xs2.json": "56d47ad12d6548a8d3d50a79be96451411f18d5b77064de7b8544bb2da22988f",
        },
    },
}
# DeepSeek-V4.1-Flash-1017's DSpark geometry, for a GGUF that carries only dspark.target_layers (ISTA's): the values
# unsloth's UD-Q8_K_XL metadata and Strata's pack of the same files carry. pack_gguf.py reads them from the GGUF with
# a default of 0, and a drafter whose block size is 0 is loaded but never drafts, silently (Maya v1.1.27-v1.1.29;
# docs/UPSTREAM.md tracks it). Written only when the pack says 0, so a pack_gguf.py that fills them wins.
DSPARK_GEOMETRY = {"dspark_block_size": 5, "dspark_noise_token_id": 128799, "dspark_markov_rank": 256,
                   "dspark_n_routed_experts": 128, "dspark_num_experts_per_tok": 3}


def say(msg: str) -> None:
    print(f"[maya-recipe] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[maya-recipe] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def read_json(p: Path) -> dict:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_json(p: Path, data: dict) -> None:
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, p)


def stamp(files: list[Path]) -> list[dict]:
    return [{"name": f.name, "size": f.stat().st_size, "mtime_ns": f.stat().st_mtime_ns} for f in files]


def files_of(tag: str, src: Path, dspark: Path) -> tuple[list[Path], list[Path]]:
    """(the model's files in /gguf, the drafter's in /dspark), all present, else a stop naming what's missing."""
    w = WEIGHTS[tag]
    model = [src / n for n in w["gguf"]]
    drafter = [dspark / n for n in w["dspark"]]
    missing = [str(f) for f in model + drafter if not f.is_file()]
    if missing:
        die(f"missing: {', '.join(missing)} (a download still running, or the wrong folder mounted? "
            "bash scripts/setup.sh <slug> downloads both)")
    return model, drafter


def sha256(f: Path) -> str:
    h = hashlib.sha256()
    with open(f, "rb") as fh:
        for block in iter(lambda: fh.read(16 << 20), b""):
            h.update(block)
    return h.hexdigest()


def verify(tag: str, files: list[Path], d: Path) -> None:
    rec = d / "verified.json"
    now = stamp(files)
    if read_json(rec).get("files") == now:
        say("files already verified")
        return
    want = {**WEIGHTS[tag]["gguf"], **WEIGHTS[tag]["dspark"]}
    say(f"checking {len(files)} files' SHA-256 (once; minutes for ~255 GB) ...")
    with ThreadPoolExecutor(max_workers=min(4, len(files))) as pool:   # hashlib frees the GIL: the disk sets the pace
        got = dict(zip(files, pool.map(sha256, files)))
    bad = [f"{f.name}: {h}, want {want[f.name]}" for f, h in got.items() if h != want[f.name]]
    if bad:
        die("SHA-256 mismatch (a damaged or partial download; download it again): " + "; ".join(bad))
    write_json(rec, {"tag": tag, "files": now})
    say("every file matches its SHA-256")


def pack(model: list[Path], drafter: list[Path], d: Path, repack: bool) -> Path:
    p = d / "pack"
    files = model + drafter
    rec = read_json(p / "sources.json").get("files")
    if not repack and (p / "tensors.txt").is_file() and rec == stamp(files):
        say(f"pack up to date: {p}")
        return p
    why = "REPACK=1" if repack else ("no pack yet" if not (p / "tensors.txt").is_file() else
                                     "a file changed after the pack was built")
    say(f"building the pack ({why}; seconds: it indexes the files, no weights copied) ...")
    tmp = d / "pack.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    dspark_json = next(f for f in drafter if f.suffix == ".json")
    r = subprocess.run([str(MAYA / ".venv/bin/python"), str(MAYA / "tools/ds4/pack_gguf.py"),
                        "--model", str(model[0].parent), "--out", str(tmp), "--drafter", str(dspark_json),
                        "--shards", *[f.name for f in model]], cwd=str(MAYA))
    if r.returncode != 0:
        die(f"tools/ds4/pack_gguf.py stopped (exit {r.returncode}); the old pack, if any, is unchanged")
    write_json(tmp / "sources.json", {"files": stamp(files)})
    if p.exists():
        for keep in ("expert-profile.bin", "slots"):   # the learned routing counts, saved conversations
            if (p / keep).exists():
                shutil.move(str(p / keep), str(tmp / keep))
        shutil.rmtree(p)
    os.replace(tmp, p)
    say(f"pack built: {p}")
    return p


def seed_profile(p: Path) -> None:
    """The engine places experts by the routing counts in <pack>/expert-profile.bin and keeps adding to them; a new
    pack starts from DeepSeek's shipped profile, as Maya's setup does."""
    prof = p / "expert-profile.bin"
    if not prof.exists():
        shutil.copyfile(MAYA / "data/expert-profile-ds4.bin", prof)
        say("expert profile seeded from data/expert-profile-ds4.bin")


def fix_dspark(p: Path) -> None:
    """Write DSPARK_GEOMETRY into the pack's ds4.txt where pack_gguf.py left 0 (see DSPARK_GEOMETRY)."""
    f = p / "ds4.txt"
    lines = f.read_text(encoding="utf-8").splitlines()
    out, fixed = [], []
    for ln in lines:
        key, _, val = ln.partition(" ")
        if key in DSPARK_GEOMETRY and val.strip() == "0":
            ln = f"{key} {DSPARK_GEOMETRY[key]}"
            fixed.append(key)
        out.append(ln)
    if not fixed:
        return
    tmp = f.with_name(f.name + ".tmp")
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.replace(tmp, f)
    say(f"DSpark geometry missing from the GGUF: wrote DeepSeek-V4.1-Flash's ({', '.join(fixed)}); "
        "without it the drafter never drafts")


def config(tag: str, d: Path, p: Path, a) -> Path:
    gpus = [int(g) for g in a.gpus.split(",") if g.strip() != ""]
    keys, sampling, args, notes = ds4_settings.settings()   # checked once already at the start of main()
    cfg = {
        "exe": str(MAYA / "build/maya-ds4"),
        # --tp 1 on two GPUs: a layer split (each GPU its own layers, whole experts), not tensor parallel
        "args": ["--pack", str(p), "--max-context", str(a.context), "--tp", str(a.tp), "--vision", "off",
                 "--dspark", "on"],
        "cwd": str(MAYA),
        "tokenizer": str(p / "tokenizer"),
        "model_name": ds4_settings.DEFAULT_NAME,     # SERVED_NAME replaces it (ds4_settings.py)
        "gpu": gpus,
        "sampling": sampling,                         # DeepSeek's 1.0 / 1.0 unless TEMP / TOP_P / ... say otherwise
        "lib_dirs": [],
        "port": 8080,
        "host": "0.0.0.0",
        "log": str(d / "maya-ds4.log"),
        "installer": {"quant": tag, "written_by": "club-3090 ds4_prepare.py"},
    }
    cfg.update(keys)                                  # reasoning_effort (high unless set), thinking_budget, model_name
    cfg["args"] += args                               # --cpu-threads
    for n in notes:
        say(n)
    out = d / "maya-ds4.json"
    write_json(out, cfg)
    shown = ", ".join([f"{k}={v}" for k, v in keys.items()] + [f"sampling.{k}={v}" for k, v in sampling.items()]
                      + [" ".join(args)])
    say(f"config: {out} (GPUs {gpus}, --tp {a.tp}, context {a.context}; {shown})")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, choices=sorted(WEIGHTS))
    ap.add_argument("--src", default="/gguf")
    ap.add_argument("--dspark", default="/dspark")
    ap.add_argument("--data", default="/data")
    ap.add_argument("--context", type=int, default=65536)
    ap.add_argument("--gpus", default="0,1")
    ap.add_argument("--tp", type=int, default=1)
    ap.add_argument("--verify", default="1")
    ap.add_argument("--repack", default="0")
    a = ap.parse_args()
    try:
        ds4_settings.settings()                       # a bad setting stops here, before the SHA-256 check and the pack
    except ds4_settings.Bad as e:
        die(str(e))
    d = Path(a.data) / a.tag
    d.mkdir(parents=True, exist_ok=True)
    model, drafter = files_of(a.tag, Path(a.src), Path(a.dspark))
    if a.verify != "0":
        verify(a.tag, model + drafter, d)
    else:
        say("VERIFY=0: the files' SHA-256 is not checked")
    p = pack(model, drafter, d, a.repack == "1")
    seed_profile(p)
    fix_dspark(p)
    config(a.tag, d, p, a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
