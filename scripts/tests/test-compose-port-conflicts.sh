#!/usr/bin/env bash
# Gate: no two DISTINCT active slugs from DIFFERENT models share a default_port.
#
# Why: default_port is the host port the launcher/c3/estate bind a slug to. Two
# different models on the same port can't co-reside (GPU0+GPU1 small models), and
# it breaks slug<->port identity in c3 even on this one-model-at-a-time rig. Ports
# were historically assigned per-model with no global check, so overlaps crept in
# (qwen3.8's 8091-8112 block overlapped nemotron; iq4nl/iq4xs shared 8086 with
# inkling). This gate stops that regressing.
#
# Policy (three cases, only the third fails):
#   (a) ALIAS         — same compose_path under two slug names  -> OK
#   (b) SAME-MODEL    — variants of ONE model (mutually exclusive) -> OK
#   (c) CROSS-MODEL   — distinct models, distinct compose_paths  -> FAIL
#
# Deprecated slugs are excluded (they're not launchable). Known pre-existing
# cross-model collisions are allowlisted (ALLOW) and tracked for a separate
# hygiene PR; the gate ALSO fails if an ALLOW entry no longer collides, so the
# list can't silently rot (negative control).
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)

# Force Python UTF-8 mode (PEP 540) before the first python3 call (#779). Guarded
# by test-locale-utf8.sh; exported so children inherit it.
export PYTHONUTF8="${PYTHONUTF8:-1}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export PYTHONPATH="$ROOT_DIR${PYTHONPATH:+:$PYTHONPATH}"

python3 - <<'PY'
import sys, collections
# C4-rev: merged view — LOCAL layer ports are conflict-checked against core.
from scripts.lib.profiles.compose_registry import get_registry

R = get_registry()

# Pre-existing cross-model collisions, tracked for a separate port-hygiene PR.
# Burn these down and DELETE them from here — the gate fails if a listed port
# stops colliding, so a stale entry can't hide.
# (Empty — the two pre-existing cross-model collisions were resolved in this
#  port-hygiene PR: tess-dual-mtp -> 8115, deepseek-flash-multi4 -> 8116. Re-add a
#  port here only as a *tracked* temporary exception for a NEW pre-existing overlap;
#  the gate fails if a listed port no longer collides.)
ALLOW = set()

byport = collections.defaultdict(list)
for slug, e in R.items():
    if (e.get("status") or "").lower() == "deprecated":
        continue
    port = e.get("default_port")
    if port is None:
        continue
    byport[port].append((slug, e.get("model"), e.get("compose_path")))

conflicts = []
allow_still_colliding = set()
for port, entries in sorted(byport.items()):
    if len(entries) < 2:
        continue
    paths = {p for _, _, p in entries}
    models = {m for _, m, _ in entries}
    if len(paths) == 1:      # (a) alias — same compose_path
        continue
    if len(models) == 1:     # (b) same-model, mutually exclusive
        continue
    # (c) cross-model collision
    if port in ALLOW:
        allow_still_colliding.add(port)
        continue
    conflicts.append((port, entries))

fail = False

if conflicts:
    fail = True
    print("FAIL: cross-model default_port collisions (distinct models sharing a host port):")
    for port, entries in conflicts:
        print(f"  PORT {port}:")
        for slug, model, path in sorted(entries):
            print(f"    {slug}  [{model}]")
    print("Fix: reassign one side to a free default_port — registry default_port +")
    print("     the compose ${PORT:-NNNN} + any doc-table/port references. If it is a")
    print("     genuine, tracked pre-existing overlap, add the port to ALLOW with a note.")

stale = ALLOW - allow_still_colliding
if stale:
    fail = True
    print(f"FAIL: ALLOW lists port(s) {sorted(stale)} that no longer cross-model-collide.")
    print("      Remove them from ALLOW — the debt they tracked is paid.")

if fail:
    sys.exit(1)

active = sum(len(v) for v in byport.values())
print(f"OK: no un-allowlisted cross-model port collisions "
      f"({active} active slug-ports; ALLOW={sorted(ALLOW)} still valid).")
PY

# Gate 2: every CURATED slug's default_port is in the curated band, 8010-8199.
# 20200-20299 is the local layer's: promote.py gives each local model
# 20200 + crc32(id) % 100, so a curated slug there can land on a user's own model
# with the next `git pull`, and gate 1 above can't see it (it checks one merged
# registry, not which layer a port belongs to). bucko's two slugs shipped on
# 20240/20272 that way, because export_pr.py carried their local ports into core;
# it now assigns a curated port itself. Core entries only, since local slugs live
# in 202xx by design. The bands come from export_pr.py, which assigns the ports.
python3 - <<'PY'
import sys
from scripts.lib.profiles import compose_registry as cr
from scripts.lib.profiles.export_pr import CURATED_PORTS, LOCAL_PORTS

band = f"{CURATED_PORTS.start}-{CURATED_PORTS.stop - 1}"


def outside(entries):
    return sorted((s, e.get("default_port")) for s, e in entries.items()
                  if e.get("default_port") is not None and e["default_port"] not in CURATED_PORTS)


# Negative control first: the check has to fire on a 202xx port and on one just
# past the band, and pass one inside it, or a green below means nothing.
probe = {"x/local-band": {"default_port": LOCAL_PORTS.start + 40},
         "x/past-band": {"default_port": CURATED_PORTS.stop},
         "x/in-band": {"default_port": CURATED_PORTS.start}}
if [s for s, _ in outside(probe)] != ["x/local-band", "x/past-band"]:
    print("FAIL: the curated-band check doesn't tell a 202xx port from a curated one (negative control)")
    sys.exit(1)

bad = outside(cr.COMPOSE_REGISTRY)
if bad:
    print(f"FAIL: curated slugs off the curated port band {band}:")
    for slug, port in bad:
        where = "the local layer's 202xx band" if port in LOCAL_PORTS else "outside the band"
        print(f"  {slug}: {port} ({where})")
    print("Fix: give it a free curated port: the registry default_port and the compose's")
    print("     ${PORT:-NNNN}. export_pr.py picks one itself; if the band is full, extend")
    print("     CURATED_PORTS there (and the band in docs/BRING_YOUR_OWN.md).")
    sys.exit(1)
print(f"OK: all {len(cr.COMPOSE_REGISTRY)} curated slugs are on the curated port band {band}.")
PY

# Gate 3: no curated slug on a port the repo's own services listen on (Open WebUI 8080,
# SearXNG 8088, the studio director 8090, ComfyUI 8188, the studio sidecars 8189-8195, ...).
# A slug there can't run beside them, and `gpu-mode.sh status` reads its port as theirs.
# #1674 put strata on ComfyUI's and the gallery's ports. The ports are read from services/
# by export_pr.service_ports, the same reader the export uses to skip them.
python3 - <<'PY'
import sys
from pathlib import Path
from scripts.lib.profiles import compose_registry as cr
from scripts.lib.profiles.export_pr import service_ports

# Pre-existing overlaps, tracked for a maintainer call (both slugs predate the gate).
# Burn these down and DELETE them from here: the gate fails when a listed one is gone.
ALLOW = {
    (8080, "vllm/qwen-agentworld-35b-a3b-dual-awq-int4"),   # Open WebUI's port; a Production slug
    (8090, "llamacpp/qwen38-27b-single-iq4xs"),             # the studio director's port
}

svc = service_ports(Path("."))
# Positive control first: the reader still finds one port of each kind it reads (a
# published compose port, a host-network service's listen port, a host-run server's
# default), or an empty set would pass every slug below.
missing = {8188: "ComfyUI's published port", 8190: "the studio orchestrator's host-network port",
           8195: "the studio Production server's default"}
missing = {p: what for p, what in missing.items() if p not in svc}
if missing:
    print("FAIL: service_ports no longer finds " + "; ".join(f"{p} ({w})" for p, w in missing.items()))
    sys.exit(1)

hits = {(int(e["default_port"]), s) for s, e in cr.COMPOSE_REGISTRY.items()
        if str(e.get("default_port") or "").isdigit() and int(e["default_port"]) in svc}
fail = False
new = sorted(hits - ALLOW)
if new:
    fail = True
    print("FAIL: curated slugs on a port the repo's own services listen on:")
    for port, slug in new:
        print(f"  {slug}: {port}")
    print("Fix: move the slug to a free curated port (registry default_port and the compose's")
    print("     ${PORT:-NNNN}); export_pr.py picks one that no slug and no service holds.")
stale = sorted(ALLOW - hits)
if stale:
    fail = True
    print(f"FAIL: ALLOW lists {stale}, which no longer overlap a service port. Remove them.")
if fail:
    sys.exit(1)
print(f"OK: no curated slug on a service port ({len(svc)} service ports; ALLOW={sorted(p for p, _ in ALLOW)} still valid).")
PY
