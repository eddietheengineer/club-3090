#!/usr/bin/env python3
"""strata-pin-bump: move the `strata` or `strata-maya` engine pin to a new release in one command.

Called by scripts/strata-pin-bump.sh, which documents the usage. What a bump checks, and when to skip a
release, is the bump rule in docs/NIGHTLY_BUMP_RUNBOOK.md ("Strata and Project Maya: the bump rule");
this does its mechanical part:

  1. resolve the release to an image digest (docker pull), read its labels and the upstream commit;
  2. check, in the new image, what our launchers rely on (below) and refuse when one changed;
  3. edit every place the pin lives: engine-pin-bump.sh (install.spec + compose image defaults),
     lineage.source_ref, the two `pin-` lines in the engine profile, and (Strata) the "Pinned" line of
     docs/engines/STRATA.md. docs/UPSTREAM.md's Pinned images table carries no pin, so a bump never edits it;
  4. re-record the settings evidence (engine_config_reads.py verify <engine> --record);
  5. boot one slug through switch.sh, check the container runs the pinned digest, send 3 warm-up
     requests, run verify-full, read the host's free RAM and swap, and stop it;
  6. print a summary for the pin PR, with the upstream releases the bump skipped.

Every edit target must match exactly once, and all of them are checked before anything is written: a
target that is silently skipped would leave a stale pin line under a successful run. A changed format
is a refusal that names the file; fix the format or this script, not both by hand.

Exit: 0 done; 1 a check, the record or the boot failed; 2 refused (bad arguments, unknown release,
already pinned, a target that doesn't match).
"""
from __future__ import annotations

import argparse
import ast
import datetime as dt
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

ENGINES = {
    "strata": {
        "name": "Strata",
        "repo": "ghcr.io/niko1221/strata",
        "github": "Niko1221/Strata",
        "families": {
            "ista": "strata/qwen3.8-flash-next-iq3s-dual",
            "swift": "strata/qwen3.8-flash-next-swift15-abliterated-iq3s-dual",
        },
        "default_slug": None,  # the bump rule: the family the release notes touch, else alternate
    },
    "strata-maya": {
        "name": "Project Maya",
        "repo": "ghcr.io/noonghunna/strata-maya-club3090",
        "github": "mw00/project-maya",
        "families": {},
        "default_slug": "strata-maya/glm53-flash-dual-maya-l",
    },
}

# The settings our launcher hands Strata's own entrypoint (/opt/strata/entrypoint.sh); the runbook lists
# them as a volatile interface. A release that stops reading one breaks a launch setting quietly.
STRATA_ENTRYPOINT_ENV = ("MODEL", "FAMILY", "MODEL_PATH", "CONTEXT", "KV", "VISION", "GPUS", "PRESET", "API_KEY")

STRATA_CONFIG = "models/qwen3.8-flash-next/strata/launcher/strata_config.py"
MAYA_PREPARE = "models/glm-5.3-flash/strata-maya/launcher/maya_prepare.py"
STRATA_DOC = "docs/engines/STRATA.md"


class Refuse(Exception):
    """Exit 2: nothing was written."""


class Failed(Exception):
    """Exit 1: a check, the record or the boot failed."""


def say(msg: str = "") -> None:
    print(msg, flush=True)


def run(cmd, cwd=None, env=None, check=True, timeout=None) -> subprocess.CompletedProcess:
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", timeout=timeout)
    if check and p.returncode != 0:
        raise Failed(f"`{' '.join(map(str, cmd))}` failed (exit {p.returncode}):\n{(p.stderr or p.stdout).strip()[-2000:]}")
    return p


def normalize_version(engine: str, release: str) -> str:
    """Strata's image tag and version label have no `v` (0.2.3); Maya's tag and label keep it (v1.1.25)."""
    r = release.strip()
    if not re.fullmatch(r"v?\d+(\.\d+){1,3}", r):
        raise Refuse(f"'{release}' is not a release number (0.2.3 / v1.1.25)")
    bare = r.lstrip("v")
    return bare if engine == "strata" else f"v{bare}"


def release_tag(engine: str, version: str) -> str:
    return f"v{version.lstrip('v')}"


def image_tag(engine: str, version: str) -> str:
    return f"{version}-cuda13" if engine == "strata" else version


# ── 1. resolve ──────────────────────────────────────────────────────────────────────────────────────

def resolve(engine: str, version: str) -> dict:
    cfg = ENGINES[engine]
    tag_ref = f"{cfg['repo']}:{image_tag(engine, version)}"
    say(f"[resolve] docker pull {tag_ref}")
    p = run(["docker", "pull", tag_ref], check=False, timeout=3600)
    if p.returncode != 0:
        hint = (" (Maya's image is ours: publish it first with "
                f"`build.sh --tag {version} --push`)") if engine == "strata-maya" else ""
        raise Refuse(f"cannot pull {tag_ref}{hint}:\n{(p.stderr or p.stdout).strip()[-800:]}")
    # The tag's manifest digest is the one the pull reports. An image can carry several repo digests
    # (upstream re-ran its image workflow), so RepoDigests alone can't say which one the tag means now.
    m = re.search(r"^Digest: (sha256:[0-9a-f]{64})$", p.stdout, re.M)
    if not m:
        raise Refuse(f"`docker pull {tag_ref}` reported no digest:\n{p.stdout.strip()[-400:]}")
    ref = f"{cfg['repo']}@{m.group(1)}"
    info = json.loads(run(["docker", "image", "inspect", tag_ref, "--format", "{{json .}}"]).stdout)
    if ref not in (info.get("RepoDigests") or []):
        raise Refuse(f"{tag_ref}: the pulled digest {m.group(1)[:19]}… is not among the image's repo digests")
    labels = (info.get("Config") or {}).get("Labels") or {}
    got = labels.get("org.opencontainers.image.version", "")
    if got != version:
        raise Refuse(f"{tag_ref} says it is version '{got}', not {version}: refusing to pin it")
    facts = {"version": version, "tag_ref": tag_ref, "ref": ref,
             "short": ref.split("@sha256:")[1][:8], "date": dt.date.today().isoformat()}
    if engine == "strata":
        eng = labels.get("com.strata.engine", "")
        if not re.match(r"\d+\.\d+", eng):
            raise Refuse(f"{tag_ref}: no engine version in its com.strata.engine label ('{eng}')")
        facts["engine"] = eng.split("-")[0]
        facts["upstream"] = upstream_commit(cfg["github"], release_tag(engine, version))
    else:
        for k in ("club3090.upstream.revision", "org.opencontainers.image.revision", "club3090.cuda_architectures"):
            if not labels.get(k):
                raise Refuse(f"{tag_ref}: label {k} is missing; was it built by image/build.sh?")
        facts["upstream"] = labels["club3090.upstream.revision"]
        facts["recipe"] = labels["org.opencontainers.image.revision"][:8]
        facts["archs"] = labels["club3090.cuda_architectures"]
    if not re.fullmatch(r"[0-9a-f]{40}", facts["upstream"]):
        raise Refuse(f"upstream commit for {version} is not a commit sha: '{facts['upstream']}'")
    return facts


def upstream_commit(github: str, tag: str) -> str:
    # gh api prints an error body to stdout on a 404, so the exit code and the sha's shape decide.
    p = run(["gh", "api", f"repos/{github}/commits/{tag}", "--jq", ".sha"], check=False, timeout=60)
    sha = p.stdout.strip()
    if p.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise Refuse(f"cannot resolve {github} tag {tag} to a commit: {(p.stderr or p.stdout).strip()[:300]}")
    return sha


def skipped_releases(github: str, old_tag: str, new_tag: str) -> str:
    p = run(["gh", "api", f"repos/{github}/releases?per_page=100"], check=False, timeout=60)
    try:
        rel = [r for r in json.loads(p.stdout) if not r.get("draft")]
        when = {r["tag_name"]: r["published_at"] for r in rel}
        lo, hi = when[old_tag], when[new_tag]
    except Exception:
        return "unknown (could not read the release list)"
    between = sorted((r["published_at"], r["tag_name"]) for r in rel if lo < r["published_at"] < hi)
    return ", ".join(t for _, t in between) or "none"


# ── 2. what our launchers rely on, checked in the new image ────────────────────────────────────────

def image_checks(root: Path, engine: str, ref: str) -> list[str]:
    if engine == "strata":
        return strata_checks(root, ref)
    return maya_checks(root, ref)


def _in_image(ref: str, script: str) -> str:
    return run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "sh", ref, "-c", script],
               timeout=300).stdout


def strata_checks(root: Path, ref: str) -> list[str]:
    src = (root / STRATA_CONFIG).read_text(encoding="utf-8")
    kv_formats = ast.literal_eval(re.search(r"^KV_FORMATS = (\([^)]*\))", src, re.M).group(1))
    setup_spec = ast.literal_eval(re.search(r'^SETUP_SPEC = ("[^"]*")', src, re.M).group(1))
    launch_help = _in_image(ref, "strata launch --help 2>&1")
    para = re.search(r"--kv FORMAT\s+(.*?)(?:\n\s*--|\Z)", launch_help, re.S)
    offered = set(re.findall(r"\b[a-z]+[0-9][a-z0-9_]*\b", para.group(1))) if para else set()
    missing = [k for k in kv_formats if k not in offered]
    if missing:
        raise Failed(f"`strata launch --kv` no longer offers {', '.join(missing)} (strata_config.py KV_FORMATS: "
                     f"{', '.join(kv_formats)}; the image offers {', '.join(sorted(offered)) or 'none'})")
    help_text = _in_image(ref, 'e=$(ls /opt/strata/components/engine/*/strata) && "$e" --help 2>&1')
    spec = re.search(r"--spec N\s+(.*?)(?:\n\s*--|\Z)", help_text, re.S)
    words = " ".join(spec.group(1).split()) if spec else ""
    m = re.search(r"setup writes (\d+)", words)
    if not m or m.group(1) != setup_spec:
        raise Failed(f"`--spec` help no longer says setup writes {setup_spec} (strata_config.py SETUP_SPEC): "
                     f"'{words[:160]}'")
    entry = _in_image(ref, "cat /opt/strata/entrypoint.sh")
    gone = [v for v in STRATA_ENTRYPOINT_ENV if not re.search(r"\$\{?" + v + r"\b", entry)]
    if gone:
        raise Failed(f"/opt/strata/entrypoint.sh no longer reads {', '.join(gone)}, which our launcher sets")
    new = sorted(offered - set(kv_formats))
    return [f"`strata launch --kv` still offers {', '.join(kv_formats)}" + (f" (new: {', '.join(new)})" if new else ""),
            f"--spec help still says setup writes {setup_spec}",
            f"the entrypoint still reads {', '.join(STRATA_ENTRYPOINT_ENV)}"]


def maya_checks(root: Path, ref: str) -> list[str]:
    src = (root / MAYA_PREPARE).read_text(encoding="utf-8")
    quants = ast.literal_eval(re.search(r"^MODELS = (\{[^}]*\})", src, re.M).group(1))
    out = run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "/opt/maya/.venv/bin/python", ref, "-c",
               'import json, sys; sys.path.insert(0, "/opt/maya"); import maya; print(json.dumps(sorted(maya.MODELS)))'],
              timeout=300).stdout
    have = set(json.loads(out.strip().splitlines()[-1]))
    gone = sorted(q for q in quants.values() if q not in have)
    if gone:
        raise Failed(f"maya.py's MODELS no longer has {', '.join(gone)}, which maya_prepare.py MODELS names")
    return [f"maya.py's MODELS still has {', '.join(sorted(quants.values()))}"]


# ── 3. the edits ────────────────────────────────────────────────────────────────────────────────────

def one(pattern: str, text: str, where: str, flags=0) -> re.Match:
    found = list(re.finditer(pattern, text, flags))
    if len(found) != 1:
        raise Refuse(f"{where}: expected exactly one match for /{pattern}/, found {len(found)}. "
                     "The format changed: fix it or scripts/lib/strata_pin_bump.py")
    return found[0]


def parse_pin_current(line: str) -> dict:
    parts = line.split(" · ")
    fields = {"version": parts[0]}
    for p in parts[1:]:
        k, _, v = p.partition(" ")
        fields[k] = v
    return fields


def render_pin_current(engine: str, f: dict) -> str:
    keys = ("upstream", "engine") if engine == "strata" else ("upstream", "recipe", "archs")
    return " · ".join([f["version"]] + [f"{k} {f[k]}" for k in keys] + [f"pinned {f['pinned']}", f"booted {f['booted']}"])


def engine_yml(root: Path, engine: str) -> Path:
    return root / "scripts/lib/profiles/engines" / f"{engine}.yml"


def current_pin(root: Path, engine: str) -> dict:
    text = engine_yml(root, engine).read_text(encoding="utf-8")
    where = f"scripts/lib/profiles/engines/{engine}.yml"
    spec = one(r"^  spec: (\S+)$", text, where, re.M).group(1)
    cur = parse_pin_current(one(r"^  # pin-current: (.+)$", text, where, re.M).group(1))
    need = ("upstream", "pinned", "booted") + (("engine",) if engine == "strata" else ("recipe", "archs"))
    if any(k not in cur for k in need):
        raise Refuse(f"{where}: the pin-current line lacks {', '.join(k for k in need if k not in cur)}")
    cur["spec"] = spec
    cur["short"] = spec.split("@sha256:")[1][:8] if "@sha256:" in spec else spec
    return cur


def plan_edits(root: Path, engine: str, old: dict, new: dict) -> dict[str, str]:
    """{relative path: new text} for every edit except engine-pin-bump.sh's. Refuses before writing."""
    out = {}
    yml_rel = f"scripts/lib/profiles/engines/{engine}.yml"
    text = (root / yml_rel).read_text(encoding="utf-8")
    one(r'^  source_ref: "[0-9a-f]{40}"$', text, yml_rel, re.M)
    text = re.sub(r'^  source_ref: "[0-9a-f]{40}"$', f'  source_ref: "{new["upstream"]}"', text, flags=re.M)
    cur = dict(new, upstream=new["upstream"][:8], pinned=new["date"], booted="pending")
    text = re.sub(r"^  # pin-current: .+$", lambda m: "  # pin-current: " + render_pin_current(engine, cur),
                  text, flags=re.M)
    one(r"^  # pin-earlier: ", text, yml_rel, re.M)
    if engine == "strata":
        outgoing = f"{old['version']} `{old['short']}…` (upstream {old['upstream']}, engine {old['engine']}, {old['pinned']})"
    else:
        outgoing = f"{old['version']} `{old['short']}…` (upstream {old['upstream']}, recipe {old['recipe']}, {old['pinned']})"
    text = re.sub(r"^  # pin-earlier: ", lambda m: m.group(0) + outgoing + "; ", text, count=1, flags=re.M)
    out[yml_rel] = text

    if engine == "strata":
        doc = (root / STRATA_DOC).read_text(encoding="utf-8")
        one(r"^- \*\*Pinned:\*\* .*$", doc, STRATA_DOC, re.M)
        pinned = (f"- **Pinned:** {new['version']} (engine {new['engine']}), since {new['date']} "
                  f"({old['version']}, engine {old['engine']}, from {old['pinned']}).")
        out[STRATA_DOC] = re.sub(r"^- \*\*Pinned:\*\* .*$", lambda m: pinned, doc, flags=re.M)
    return out


def write_atomic(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)


def show_diff(root: Path, edits: dict[str, str]) -> None:
    for rel, text in edits.items():
        before = (root / rel).read_text(encoding="utf-8").splitlines(keepends=True)
        sys.stdout.writelines(difflib.unified_diff(before, text.splitlines(keepends=True), f"a/{rel}", f"b/{rel}"))


def set_booted(root: Path, engine: str, booted: str) -> None:
    path = engine_yml(root, engine)
    text = path.read_text(encoding="utf-8")
    m = one(r"^  # pin-current: (.+)$", text, str(path.relative_to(root)), re.M)
    f = parse_pin_current(m.group(1))
    f["booted"] = booted
    write_atomic(path, text[:m.start(1)] + render_pin_current(engine, f) + text[m.end(1):])


# ── 5. boot ─────────────────────────────────────────────────────────────────────────────────────────

def lookup(root: Path, fn: str, slug: str) -> str:
    p = run(["bash", "-c", f'source scripts/lib/registry-lookup.sh && {fn} "$1"', "_", slug], cwd=root, check=False)
    val = p.stdout.strip()
    if p.returncode != 0 or not val:
        raise Refuse(f"the registry has no {fn.split('_')[-1]} for {slug}")
    return val


def boot(root: Path, engine: str, slug: str, ref: str, logdir: Path) -> dict:
    container = lookup(root, "registry_lookup_container", slug)
    port = lookup(root, "registry_lookup_port", slug)
    url = f"http://localhost:{port}"
    res = {"slug": slug, "container": container}
    env = dict(os.environ, READY_TIMEOUT=os.environ.get("READY_TIMEOUT", "1800"))
    say(f"[boot] switch.sh --force {slug} (log: {logdir}/boot.log)")
    with open(logdir / "boot.log", "w", encoding="utf-8") as log:
        rc = subprocess.run(["bash", "scripts/switch.sh", "--force", slug], cwd=root, env=env,
                            stdout=log, stderr=subprocess.STDOUT).returncode
    blog = (logdir / "boot.log").read_text(encoding="utf-8", errors="replace")
    m = re.search(r"ready \((\d+)s\)", blog)
    res["ready"] = f"{m.group(1)} s" if m else "?"
    try:
        if rc != 0:
            raise Failed(f"switch.sh exited {rc}; see {logdir}/boot.log")
        image = run(["docker", "inspect", container, "--format", "{{.Config.Image}}"]).stdout.strip()
        if image != ref:
            raise Failed(f"{container} runs {image}, not the pinned {ref}")
        res["image"] = "the pinned digest"
        key = run(["docker", "exec", container, "sh", "-c", 'printf %s "${API_KEY:-}"']).stdout
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # localhost: never via a proxy
        hdr = {"Content-Type": "application/json"}
        if key:
            hdr["Authorization"] = f"Bearer {key}"   # in memory only; never printed or put on a command line
        req = urllib.request.Request(url + "/v1/models", headers=hdr)
        model = json.load(opener.open(req, timeout=60))["data"][0]["id"]
        body = json.dumps({"model": model, "max_tokens": 32,
                           "messages": [{"role": "user", "content": "Say hello in one short sentence."}]}).encode()
        for i in range(3):
            req = urllib.request.Request(url + "/v1/chat/completions", data=body, headers=hdr)
            json.load(opener.open(req, timeout=600))
        res["warmups"] = "3 ok"
        say(f"[boot] verify-full against {url} (log: {logdir}/verify-full.log)")
        with open(logdir / "verify-full.log", "w", encoding="utf-8") as log:
            vrc = subprocess.run(["bash", "scripts/verify-full.sh"], cwd=root, env=dict(os.environ, URL=url),
                                 stdout=log, stderr=subprocess.STDOUT).returncode
        vlog = re.sub(r"\x1b\[[0-9;]*m", "", (logdir / "verify-full.log").read_text(encoding="utf-8", errors="replace"))
        res["verify"] = f"exit {vrc}, {vlog.count('✓')} ✓ / {vlog.count('✗')} ✗"
        mem = dict(l.split(":", 1) for l in Path("/proc/meminfo").read_text().splitlines() if ":" in l)
        gib = lambda k: int(mem[k].split()[0]) / 1048576
        res["memory"] = (f"MemAvailable {gib('MemAvailable'):.1f} GiB, swap used "
                         f"{gib('SwapTotal') - gib('SwapFree'):.1f} GiB")
        if vrc != 0:
            raise Failed(f"verify-full exited {vrc}; see {logdir}/verify-full.log")
    finally:
        subprocess.run(["docker", "stop", container], capture_output=True)
        subprocess.run(["docker", "rm", container], capture_output=True)
    return res


# ── main ────────────────────────────────────────────────────────────────────────────────────────────

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="strata-pin-bump.sh", add_help=True)
    ap.add_argument("engine", choices=sorted(ENGINES))
    ap.add_argument("release")
    ap.add_argument("--slug")
    ap.add_argument("--family")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--no-boot", action="store_true")
    a = ap.parse_args(argv)
    root = Path(os.environ.get("STRATA_PIN_BUMP_ROOT") or Path(__file__).resolve().parents[2])
    engine, cfg = a.engine, ENGINES[a.engine]
    try:
        version = normalize_version(engine, a.release)
        old = current_pin(root, engine)
        if old["version"] == version:
            raise Refuse(f"{engine} is already pinned to {version}")

        if not a.check:
            branch = run(["git", "symbolic-ref", "--short", "HEAD"], cwd=root, check=False).stdout.strip()
            if branch in ("", "master", "main"):
                raise Refuse(f"the checkout is on '{branch or 'no branch'}': run the bump from a worktree on its own branch")
        slug = None
        if not (a.check or a.no_boot):
            if a.slug and a.family:
                raise Refuse("pass --slug or --family, not both")
            if a.family:
                if a.family not in cfg["families"]:
                    raise Refuse(f"--family is {', '.join(cfg['families']) or 'not used'} for {engine}")
                slug = cfg["families"][a.family]
            slug = slug or a.slug or cfg["default_slug"]
            if not slug:
                raise Refuse(f"pick the slug to boot: --family {' | '.join(cfg['families'])} (the family the "
                             f"release notes touch; else the one the last bump didn't boot: {old['booted']})")
            if not slug.startswith(f"{engine}/"):
                raise Refuse(f"{slug} is not a {engine} slug")

        new = resolve(engine, version)
        if new["ref"] == old["spec"]:
            raise Refuse(f"{new['tag_ref']} is the digest already pinned")
        say(f"[resolve] {cfg['name']} {old['version']} → {version}: {new['ref']} (upstream {new['upstream'][:8]})")
        checks = image_checks(root, engine, new["ref"])
        for c in checks:
            say(f"[check] {c}")
        edits = plan_edits(root, engine, old, new)

        pin_bump = ["bash", "scripts/engine-pin-bump.sh", engine, new["ref"]]
        env = dict(os.environ, PIN_BUMP_ROOT=str(root))
        if a.check:
            p = run(pin_bump + ["--check"], cwd=root, env=env, check=False)
            say(p.stdout.rstrip())
            show_diff(root, edits)
            say(f"[check] nothing written; would also re-record engine_config_reads for {engine}")
            return 0

        p = run(pin_bump, cwd=root, env=env, check=False)
        if p.returncode != 0:
            raise Failed(f"engine-pin-bump.sh failed (exit {p.returncode}):\n{(p.stderr or p.stdout).strip()[-1500:]}")
        edits = plan_edits(root, engine, old, new)   # again, on top of engine-pin-bump.sh's spec edit
        for rel, text in edits.items():
            write_atomic(root / rel, text)
            say(f"[edit] {rel}")
        rec = run(["python3", "scripts/lib/profiles/engine_config_reads.py", "verify", engine, "--record"], cwd=root,
                  check=False)
        if rec.returncode != 0:
            raise Failed(f"engine_config_reads verify {engine} failed:\n{(rec.stdout + rec.stderr).strip()[-1500:]}")
        recorded = (rec.stdout.strip().splitlines() or ["recorded"])[0].strip()
        say(f"[record] {recorded}")

        booted = None
        if not a.no_boot:
            logdir = Path(tempfile.mkdtemp(prefix=f"strata-pin-bump.{engine}.{version}."))
            booted = boot(root, engine, slug, new["ref"], logdir)
            set_booted(root, engine, f"{slug} (verify-full)")

        skipped = skipped_releases(cfg["github"], release_tag(engine, old["version"]), release_tag(engine, version))
        say("")
        say(f"## {cfg['name']} {old['version']} → {version}")
        say(f"- **Image:** `{new['tag_ref']}` → `{new['ref']}`")
        facts = f"upstream `{new['upstream'][:8]}`"
        facts += f", engine {new['engine']}" if engine == "strata" else f", recipe `{new['recipe']}`, archs {new['archs']}"
        say(f"- **Release:** {facts}")
        say(f"- **Releases skipped since the last pin:** {skipped}")
        say(f"- **Image checks:** {'; '.join(checks)}")
        say(f"- **Settings evidence:** {recorded}")
        if booted:
            say(f"- **Boot:** `{booted['slug']}` ready in {booted['ready']}, runs {booted['image']}, warm-ups "
                f"{booted['warmups']}, verify-full {booted['verify']}; after it: {booted['memory']}")
        else:
            say("- **Boot:** not run (--no-boot): boot one slug under the bump rule before the PR; the pin-current "
                "line says `booted pending` until then")
        say("")
        say("Next: Tier 0 + the pin guards with the GPUs idle, then the pin PR (docs/NIGHTLY_BUMP_RUNBOOK.md).")
        return 0
    except Refuse as e:
        print(f"[strata-pin-bump] refused: {e}", file=sys.stderr)
        return 2
    except Failed as e:
        print(f"[strata-pin-bump] FAILED: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
