#!/usr/bin/env python3
"""Does every live compose read each standard launch knob that applies to it, or declare why not?

test-launch-knobs proves that the knobs a compose reads are delivered and take the right values. It can't see a
knob a compose should read and doesn't: a slug whose model has a thinking switch but whose compose has no
ENABLE_THINKING, or a drafter compose without SPEC_N. ADDING_ENGINES §4 asked for those to be listed as
unsupported in the compose Caveats; nothing checked it. This does, from knob-conformance.json:

  knobs        every catalogued knob (launch-knobs.json) says when it applies to a slug:
                 "model"    the model's own template has the switch (per-model, below)
                 "drafter"  the slug has a drafter or a spec method (registry data)
                 "never"    an opt-in feature, not expected of every compose (with why)
  models       every model with a live curated slug, for each "model" knob: true, or why it doesn't apply.
               The evidence is the model's own chat template (`evidence`), never "some compose reads it":
               a new thinking model whose composes read nothing must still be expected to.
  unsupported  a capability claim: the knob can't work on these engines / models. Needs `why` and a
               `source` (a repo file and a literal it contains), and matches by engine id and model, so a new
               compose of the same pair inherits it.
  not_wired    backlog: these exact compose paths could take the knob and don't (`reads_instead` names what
               they read instead). It only shrinks: the number of (compose, knob) pairs must equal
               not_wired_ceiling, so a new entry needs the ceiling raised in the same change (visible in
               review), and wiring one needs it lowered.

Fails on: an applicable knob a compose neither reads nor covers; an entry that is stale (the compose reads the
knob now, is gone, or the knob no longer applies; an unsupported entry that excuses nothing); a knob or model
with no classification, or a classification for one that doesn't exist; an unsupported entry whose source
doesn't contain its literal; a reads_instead name the compose doesn't contain; the ceiling off by any amount.

Scope: curated, non-deprecated slugs from `registry-emit.sh --json` (what the resolver sees); the local layer is
the user's own. Commands: check | gaps (prints entries for uncovered gaps, as a starting point) | selftest.
Run by test-launch-knobs (Tier 0).
"""
from __future__ import annotations

import copy
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANIFEST = Path(__file__).resolve().with_name("knob-conformance.json")
CATALOGUE = Path(__file__).resolve().with_name("launch-knobs.json")
APPLIES = ("model", "drafter", "never")
# names a compose may read in place of a standard knob (only for `gaps` suggestions)
INSTEAD = {
    "ENABLE_THINKING": ("THINKING", "REASONING", "INSTRUCT", "NO_THINK"),
    "REASONING_EFFORT": ("EFFORT", "REASONING_LEVEL"),
    "SPEC_N": ("MTP_DEPTH", "MTP_DRAFT_N_MAX", "DFLASH_TOKENS", "NUM_SPECULATIVE_TOKENS", "DRAFT_N"),
    "THINKING_BUDGETS": ("THINKING_TOKEN_BUDGET", "REASONING_BUDGET"),
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def live_slugs(root: Path = ROOT) -> list[dict]:
    r = subprocess.run(["bash", "scripts/lib/registry-emit.sh", "--json"], cwd=root, capture_output=True,
                       text=True, encoding="utf-8")
    if r.returncode != 0:
        raise SystemExit(f"[knob-conformance] registry-emit.sh --json failed: {r.stderr.strip()[-400:]}")
    return [v for v in json.loads(r.stdout)["variants"]
            if v.get("source") == "curated" and v.get("status") != "deprecated"]


def model_key(manifest: dict, knob: str) -> str:
    return manifest["knobs"][knob].get("model_key", knob)


def applies(manifest: dict, knob: str, slug: dict) -> bool:
    k = manifest["knobs"][knob]
    if k["applies"] == "never":
        return False
    if k["applies"] == "drafter":
        return bool(slug.get("drafter") or slug.get("spec_method"))
    return manifest["models"].get(slug["model"], {}).get(model_key(manifest, knob)) is True


def reads_env(name: str, text: str) -> bool:
    """The compose reads NAME as a setting: an environment entry (`- NAME`, `- NAME=…`, `NAME:`) or a compose
    interpolation (`${NAME}`, `${NAME:-x}`, `$NAME`), not a mention in a comment."""
    code = "\n".join(line.split(" #", 1)[0] for line in text.splitlines() if not line.lstrip().startswith("#"))
    n = re.escape(name)
    return re.search(rf"^\s*-\s*{n}(?:=|\s*$)|^\s*{n}:|(?<!\$)\$\{{{n}(?:[:}}-])|(?<!\$)\${n}(?![A-Za-z0-9_])",
                     code, re.M) is not None


def gaps_of(manifest: dict, slugs: list[dict]) -> dict:
    """{(compose, knob): {"slugs": [...], "engines": {...}, "models": {...}}} for applicable knobs not read."""
    out = {}
    for s in slugs:
        for knob in manifest["knobs"]:
            if applies(manifest, knob, s) and knob not in s["knobs"]:
                g = out.setdefault((s["compose_path"], knob), {"slugs": [], "engines": set(), "models": set()})
                g["slugs"].append(s["slug"]); g["engines"].add(s["engine"]); g["models"].add(s["model"])
    return out


def matches(entry: dict, engines: set, models: set) -> bool:
    m = entry.get("match", {})
    return (not m.get("engine") or engines <= set(m["engine"])) and (not m.get("model") or models <= set(m["model"]))


def check(manifest: dict, catalogue: dict, slugs: list[dict], root: Path = ROOT) -> list[str]:
    problems = []
    cat_knobs, man_knobs = set(catalogue["knobs"]), set(manifest["knobs"])
    for k in sorted(cat_knobs - man_knobs):
        problems.append(f"{k} (launch-knobs.json) has no conformance class in knob-conformance.json: say when it "
                        f"applies (model / drafter / never)")
    for k in sorted(man_knobs - cat_knobs):
        problems.append(f"knob-conformance.json classifies {k}, which launch-knobs.json doesn't catalogue")
    for k, spec in manifest["knobs"].items():
        if spec.get("applies") not in APPLIES:
            problems.append(f"{k}: applies must be one of {', '.join(APPLIES)}")
        if spec.get("applies") == "never" and not spec.get("why"):
            problems.append(f"{k}: applies 'never' needs a why")
    if problems:
        return problems
    model_knobs = sorted({model_key(manifest, k) for k, s in manifest["knobs"].items() if s["applies"] == "model"})
    live_models = {s["model"] for s in slugs}
    for m in sorted(live_models):
        cls = manifest["models"].get(m)
        if cls is None:
            problems.append(f"model {m} has live slugs but no classification: for {', '.join(model_knobs)}, say "
                            f"true or why not, from its own chat template (evidence)")
            continue
        if not cls.get("evidence"):
            problems.append(f"model {m}: no evidence (where its chat template was read)")
        for k in model_knobs:
            v = cls.get(k)
            if v is not True and not (isinstance(v, str) and v.strip()):
                problems.append(f"model {m}: {k} must be true or a reason it doesn't apply (got {v!r})")
    for m in sorted(set(manifest["models"]) - live_models):
        problems.append(f"model {m} is classified but has no live curated slug: remove it")

    gaps = gaps_of(manifest, slugs)
    by_compose = {}
    for s in slugs:
        by_compose.setdefault(s["compose_path"], []).append(s)
    covered = set()
    for i, u in enumerate(manifest.get("unsupported", [])):
        tag = f"unsupported[{i}] ({', '.join(u.get('knobs', []))})"
        src = u.get("source") or {}
        if not u.get("why") or not src.get("file") or not src.get("contains"):
            problems.append(f"{tag}: needs why and source {{file, contains}}")
            continue
        p = root / src["file"]
        if not p.is_file() or src["contains"] not in p.read_text(encoding="utf-8"):
            problems.append(f"{tag}: source {src['file']} doesn't contain {src['contains']!r}")
        hit = [key for key, g in gaps.items() if key[1] in u["knobs"] and matches(u, g["engines"], g["models"])]
        if not hit:
            problems.append(f"{tag}: excuses no gap any more (every matching compose reads it, or none is live): remove it")
        covered |= set(hit)
    pairs = 0
    for i, nw in enumerate(manifest.get("not_wired", [])):
        comp = nw.get("compose", "")
        for knob in nw.get("knobs", []):
            pairs += 1
            tag = f"not_wired {comp} {knob}"
            if comp not in by_compose:
                problems.append(f"{tag}: no live curated slug runs this compose: remove the entry")
            elif (comp, knob) in covered:
                problems.append(f"{tag}: an unsupported entry already covers it: remove the not_wired entry")
            elif (comp, knob) not in gaps:
                problems.append(f"{tag}: the compose reads it now, or it no longer applies: remove it and lower "
                                f"not_wired_ceiling")
            else:
                covered.add((comp, knob))
        for knob, name in (nw.get("reads_instead") or {}).items():
            if knob not in nw.get("knobs", []):
                problems.append(f"not_wired {comp}: reads_instead names {knob}, which the entry doesn't list")
            elif comp in by_compose and not reads_env(name, (root / comp).read_text(encoding="utf-8")):
                problems.append(f"not_wired {comp}: reads_instead says {name} for {knob}, which the compose doesn't read")
    ceiling = manifest.get("not_wired_ceiling")
    if isinstance(ceiling, int) and pairs > ceiling:
        problems.append(f"not_wired has {pairs} (compose, knob) pairs, more than not_wired_ceiling ({ceiling}). The list only "
                        f"shrinks: wire the knob, or declare a sourced unsupported entry if the engine can't take it. "
                        f"Raising the ceiling is a decision for review, not a fix")
    elif pairs != ceiling:
        problems.append(f"not_wired has {pairs} (compose, knob) pairs and not_wired_ceiling is {ceiling}: lower the ceiling "
                        f"to {pairs}, so the list can't grow back")
    for (comp, knob), g in sorted(gaps.items()):
        if (comp, knob) not in covered:
            problems.append(f"{comp} doesn't read {knob}, which applies to {', '.join(sorted(g['slugs']))}. Read it "
                            f"(ADDING_ENGINES §4: map it onto the engine's own name), or declare it in "
                            f"knob-conformance.json: unsupported (with a source) if the engine can't take it")
    return problems


def suggest(manifest: dict, slugs: list[dict], root: Path = ROOT) -> list[dict]:
    gaps = gaps_of(manifest, slugs)
    covered = set()
    for u in manifest.get("unsupported", []):
        covered |= {key for key, g in gaps.items() if key[1] in u["knobs"] and matches(u, g["engines"], g["models"])}
    out = {}
    for (comp, knob) in sorted(gaps):
        if (comp, knob) in covered:
            continue
        e = out.setdefault(comp, {"compose": comp, "knobs": [], "reads_instead": {}})
        e["knobs"].append(knob)
        text = (root / comp).read_text(encoding="utf-8")
        for name in INSTEAD.get(model_key(manifest, knob), ()):
            if reads_env(name, text):
                e["reads_instead"][knob] = name
                break
    for e in out.values():
        if not e["reads_instead"]:
            del e["reads_instead"]
    return list(out.values())


# ---- controls on synthetic data ---------------------------------------------------------------------------

def selftest() -> int:
    cat = {"knobs": {"ENABLE_THINKING": {}, "SPEC_N": {}, "KV_OFFLOAD_GB": {}}}
    base = {
        "knobs": {"ENABLE_THINKING": {"applies": "model"}, "SPEC_N": {"applies": "drafter"},
                  "KV_OFFLOAD_GB": {"applies": "never", "why": "opt-in"}},
        "models": {"m1": {"evidence": "t", "ENABLE_THINKING": True}},
        "unsupported": [], "not_wired": [], "not_wired_ceiling": 0}
    s = lambda slug, comp, knobs, drafter=None, model="m1", engine="e1": {  # noqa: E731
        "slug": slug, "compose_path": comp, "knobs": knobs, "drafter": drafter, "spec_method": None,
        "model": model, "engine": engine}
    ok_slugs = [s("a", "c/a.yml", ["ENABLE_THINKING"]), s("b", "c/b.yml", ["ENABLE_THINKING", "SPEC_N"], drafter="mtp")]
    root = Path(__file__).resolve().parents[3]
    cases = []
    cases.append(("a conforming tree passes", base, ok_slugs, None))
    cases.append(("a compose missing an applicable knob fails", base,
                  ok_slugs + [s("c", "c/c.yml", [])], "c/c.yml doesn't read ENABLE_THINKING"))
    cases.append(("a drafter compose without SPEC_N fails", base,
                  ok_slugs + [s("d", "c/d.yml", ["ENABLE_THINKING"], drafter="x")], "doesn't read SPEC_N"))
    m = copy.deepcopy(base); m["not_wired"] = [{"compose": "c/c.yml", "knobs": ["ENABLE_THINKING"]}]
    cases.append(("a new not_wired entry fails the ceiling", m, ok_slugs + [s("c", "c/c.yml", [])], "only shrinks"))
    m = copy.deepcopy(m); m["not_wired_ceiling"] = 1
    cases.append(("...and passes with the ceiling raised in the same change", m, ok_slugs + [s("c", "c/c.yml", [])], None))
    cases.append(("a not_wired entry the compose now satisfies fails", m, ok_slugs + [s("c", "c/c.yml", ["ENABLE_THINKING"])],
                  "reads it now"))
    m = copy.deepcopy(base); m["unsupported"] = [{"knobs": ["ENABLE_THINKING"], "match": {"engine": ["e2"]}, "why": "x"}]
    cases.append(("an unsupported entry without a source fails", m, ok_slugs + [s("c", "c/c.yml", [], engine="e2")],
                  "needs why and source"))
    m = copy.deepcopy(m)   # each case keeps its own manifest: the checks run after all are built
    m["unsupported"][0]["source"] = {"file": "scripts/lib/profiles/knob_conformance.py", "contains": "def selftest"}
    cases.append(("...and covers its engine once sourced", m, ok_slugs + [s("c", "c/c.yml", [], engine="e2")], None))
    m2 = copy.deepcopy(m)
    m2["unsupported"][0]["source"]["contains"] = "".join(("no such ", "literal ", "in this file"))  # built, so absent
    cases.append(("an unsupported source that lacks its literal fails", m2, ok_slugs + [s("c", "c/c.yml", [], engine="e2")],
                  "doesn't contain"))
    cases.append(("an unsupported entry that excuses nothing fails", m, ok_slugs, "excuses no gap"))
    cases.append(("a model with live slugs but no classification fails", base,
                  ok_slugs + [s("z", "c/z.yml", [], model="m2")], "model m2 has live slugs but no classification"))
    c2 = {"knobs": dict(cat["knobs"], NEW_KNOB={})}
    bad = 0
    for what, man, sl, needle in cases:
        probs = check(man, cat, sl, root)
        good = (not probs) if needle is None else any(needle in p for p in probs)
        print(f"  {'✓' if good else '✗'} selftest: {what}" + ("" if good else f" (got {probs})"))
        bad += not good
    probs = check(base, c2, ok_slugs, root)
    good = any("NEW_KNOB (launch-knobs.json) has no conformance class" in p for p in probs)
    print(f"  {'✓' if good else '✗'} selftest: a catalogued knob with no conformance class fails")
    bad += not good
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    cmd = argv[1:]
    if cmd == ["selftest"]:
        return selftest()
    manifest, catalogue = load(MANIFEST), load(CATALOGUE)
    slugs = live_slugs()
    if cmd == ["check"]:
        problems = check(manifest, catalogue, slugs)
        for p in problems:
            print(f"  ✗ {p}")
        if not problems:
            composes = {s["compose_path"] for s in slugs}
            print(f"  ✓ knob conformance: {len(slugs)} live slugs ({len(composes)} composes) read every knob that applies, "
                  f"or declare why not ({len(manifest.get('unsupported', []))} unsupported, "
                  f"{manifest['not_wired_ceiling']} not-wired pairs)")
        return 1 if problems else 0
    if cmd == ["gaps"]:
        print(json.dumps(suggest(manifest, slugs), indent=1))
        return 0
    print("usage: knob_conformance.py check | gaps | selftest", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
