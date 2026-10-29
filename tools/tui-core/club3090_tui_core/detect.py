"""Auto-detection of serving model + endpoint.

Replicates the logic from scripts/preflight.sh::preflight_autodetect_endpoint
and preflight_autodetect_model.
"""

from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from typing import Optional

import httpx

from .engine_auth import get_with_engine_key

# Engine-internal ports: 8000=vLLM, 8080=llama.cpp, 30000=SGLang, 5000=TabbyAPI
# (exllamav3, #1360). Every use applies a name filter first (ENGINE_PREFIXES, a
# registry claim, or the cockpit's container kind), so 5000 — also a common port
# for unrelated apps — never admits a container on the port alone.
# ⚠️ Mirrored in scripts/lib/club-containers.sh and scripts/catalog.sh;
# scripts/tests/test-engine-port-set-drift.sh asserts every copy matches.
ENGINE_INTERNAL_PORTS = {"8000", "8080", "30000", "5000"}

# Recognized engine-family container prefixes
ENGINE_PREFIXES = re.compile(r"^(vllm-|llama-cpp-|ik-llama-|sglang-|beellama-|tabbyapi-|exl3-|exllamav3-|strata-|qengine-)")

# Port mapping regex: matches 0.0.0.0:8011->8000/tcp, [::]:8011->8000/tcp, 127.0.0.1:8011->8000/tcp
PORT_MAP_RE = re.compile(
    r"(?:[0-9]{1,3}(?:\.[0-9]{1,3}){3}|\[::\]):(\d+)->(8000|8080|30000|5000)/tcp"
)

# All known engine-port patterns (also match without IP prefix)
PORT_MAP_BROAD_RE = re.compile(
    r":(\d+)->(8000|8080|30000|5000)/tcp"
)

# ANY published tcp mapping.  Used ONLY for containers the registry claims by
# name: a registered engine may listen on any internal port it likes (#1219), and
# constraining it to our three curated ports is the same closed-set assumption as
# the name prefix.  Never used for unclaimed containers, which still have to look
# like an engine to be considered at all.
PORT_MAP_ANY_RE = re.compile(r":(\d+)->(\d+)/tcp")


def _registry_claims(variants) -> dict:
    """Map normalized container name -> registry row, for rows that name one.

    The registry already carries the container name and host port for every
    registered slug, core and local alike.  Detection used to ignore both and
    re-derive them by pattern-matching ``docker ps`` output, which a local slug
    can satisfy by neither construction (#1219).
    """
    claims: dict = {}
    for v in variants or []:
        if hasattr(v, "container"):
            container, port = v.container, v.port
        elif isinstance(v, dict):
            container, port = v.get("container", ""), v.get("port", 0)
        else:
            continue
        if container:
            claims[(container or "").replace("_", "-")] = (v, port)
    return claims


async def _reap(proc) -> None:
    """Kill and await a subprocess so its transport closes while the loop still lives.

    asyncio.wait_for cancels the COROUTINE, not the CHILD. Without this the process
    keeps running with a live transport; when it is finally GC'd — at interpreter
    shutdown, AFTER the loop is closed — BaseSubprocessTransport.__del__ calls
    loop.call_soon() and raises "RuntimeError: Event loop is closed" as an ignored
    exception on quit. These call sites POLL, so one orphan leaks per timeout.

    Idempotent and never raises: it runs on exception paths where a second failure
    would mask the original. An already-exited process raises ProcessLookupError
    from kill() — that is the success case, not an error.
    """
    if proc is None:
        return
    try:
        if proc.returncode is None:
            proc.kill()
    except (ProcessLookupError, AttributeError):
        pass
    except Exception:
        pass
    try:
        await proc.wait()
    except Exception:
        pass


@dataclass
class GpuInfo:
    """Information about a single GPU."""
    index: int
    utilization: int = 0       # %
    mem_used_mib: int = 0
    mem_total_mib: int = 0
    power_draw_w: float = 0.0
    power_limit_w: float = 0.0
    temp_c: int = 0
    # SM clock now / its maximum, in MHz (#1813).  ``None`` = this driver or card
    # doesn't report it ("[N/A]", "[Not Supported]", or an older nvidia-smi that
    # rejects the field) — the card renders "—", never 0, which would read as a
    # stalled GPU.
    clock_sm_mhz: Optional[int] = None
    clock_max_sm_mhz: Optional[int] = None
    # Raw ``clocks_event_reasons.active`` bitmask (``clocks_throttle_reasons.active``
    # on older drivers); ``None`` when not reported.  ``throttle_tag()`` turns it
    # into the short tag the card shows.
    clock_event_reasons: Optional[int] = None


@dataclass
class ServingTarget:
    """Resolved serving target — model + endpoint + metadata."""
    url: str = ""
    model: str = ""
    container: str = ""
    engine: str = ""           # vllm | llamacpp | ik-llama | sglang | beellama | unknown
    host_port: int = 0
    internal_port: int = 0
    slug: str = ""             # registry slug if matched
    kv_format: str = ""
    max_ctx: int = 0
    tp: int = 0
    status: str = ""           # registry status
    status_note: str = ""
    match_confidence: str = ""  # "identity" | "shape" | "" — see match_target_to_registry
    health: str = "unknown"    # serving | unreachable | multiple
    gpus: list[GpuInfo] = field(default_factory=list)

    @property
    def is_localhost(self) -> bool:
        return "localhost" in self.url or "127." in self.url or "[::1]" in self.url

    @property
    def is_active(self) -> bool:
        return bool(self.url and self.model and self.health == "serving")


def _classify_engine(internal_port: str) -> str:
    """Map internal port to engine family."""
    return {"8000": "vllm", "8080": "llamacpp", "30000": "sglang", "5000": "exllamav3"}.get(
        internal_port, "unknown"
    )


def _classify_engine_from_container(name: str) -> str:
    """Refine engine from container name prefix."""
    if name.startswith("vllm-"):
        return "vllm"
    if name.startswith("llama-cpp-") or name.startswith("ik-llama-"):
        return "llamacpp"
    if name.startswith("sglang-"):
        return "sglang"
    if name.startswith("beellama-"):
        return "beellama"
    if name.startswith(("tabbyapi-", "exl3-", "exllamav3-")):
        return "exllamav3"
    # Strata serves on 8080 and answers /props like llama-server, so its name has to
    # win over the port map, which reads 8080 as llamacpp.
    if name.startswith("strata-"):
        return "strata"
    # QEngine serves on 8080 too (and answers no /props): without its name the port map read it
    # as llamacpp, and a rebench REPORT.md's container line resolved to no family (#1846's run)
    if name.startswith("qengine-"):
        return "qengine"
    return "unknown"


async def detect_endpoint(
    container_name: Optional[str] = None,
    variants: Optional[list] = None,
) -> ServingTarget:
    """Detect the currently-serving model and endpoint.

    Args:
        container_name: If set, detect only from this container.
        variants: Registry rows (VariantRow or dict).  When supplied, any running
            container the registry claims BY NAME is treated as an engine
            regardless of its name prefix or internal port, and is preferred over
            containers matched by the naming heuristics.  Omit it and behaviour is
            exactly the previous heuristics-only detection.

    Returns:
        A ServingTarget with whatever was resolved.
    """
    target = ServingTarget()

    # Step 1: docker ps
    try:
        proc = await asyncio.create_subprocess_exec(
            "docker", "ps", "--format", "{{.Names}}|{{.Ports}}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        lines = stdout.decode().strip().split("\n")
    except (asyncio.TimeoutError, FileNotFoundError, Exception):
        await _reap(locals().get("proc"))
        target.health = "unreachable"
        return target

    # Step 2: find inference containers.
    #
    # Precedence is REGISTRY FIRST (#1219).  A container the registry claims by
    # name IS an engine — we registered it — so it is accepted whatever it is
    # called and whatever port it listens on internally.  The naming heuristics
    # below then run only for containers no registry row claims, which is what
    # keeps a hand-run container (never registered) visible.
    #
    # The old order asked a container to be NAMED with one of five curated engine
    # prefixes AND to publish one of three container-side ports.  A local slug can
    # satisfy neither by construction: the whole point of the local layer (#1202)
    # is that the user brings an engine we have never heard of.
    claims = _registry_claims(variants)

    candidates: list[tuple[str, int, int, str]] = []  # (name, host_port, internal_port, engine)
    claimed_names: set[str] = set()
    seen: set[tuple[str, int]] = set()  # dedupe by (container_name, host_port) for dual-stack

    for line in lines:
        if "|" not in line:
            continue
        name, ports_str = line.split("|", 1)

        claim = claims.get(name.replace("_", "-"))
        if claim is None and not ENGINE_PREFIXES.match(name):
            # Not registered and doesn't look like an engine — Open WebUI, qdrant…
            continue

        # A claimed container may publish several mappings (an engine port plus
        # metrics).  Prefer the one whose HOST port the registry recorded.
        port_re = PORT_MAP_ANY_RE if claim is not None else PORT_MAP_BROAD_RE
        matches = list(port_re.finditer(ports_str))
        if claim is not None:
            registry_port = claim[1]
            preferred_ports = [m for m in matches if int(m.group(1)) == registry_port]
            matches = preferred_ports or matches

        for match in matches:
            host_port = int(match.group(1))
            internal_port = int(match.group(2))

            # Dedupe dual-stack mappings (same container, same host port)
            key = (name, host_port)
            if key in seen:
                continue
            seen.add(key)

            if claim is not None:
                claimed_names.add(name)
                row = claim[0]
                engine = (
                    getattr(row, "engine", "") if hasattr(row, "engine")
                    else (row.get("engine", "") if isinstance(row, dict) else "")
                ) or ""
            else:
                engine = ""
            if not engine:
                engine = _classify_engine_from_container(name)
            if engine == "unknown" or not engine:
                engine = _classify_engine(str(internal_port))
            candidates.append((name, host_port, internal_port, engine))

    if not candidates:
        target.health = "unreachable"
        return target

    # If caller pinned a container, filter to it
    if container_name:
        candidates = [c for c in candidates if c[0] == container_name]
        if not candidates:
            target.health = "unreachable"
            return target

    # Step 3: prefer a registry-claimed container (we know what it is), then one
    # matching the naming heuristic, else the first match.
    claimed = [c for c in candidates if c[0] in claimed_names]
    preferred = claimed or [c for c in candidates if ENGINE_PREFIXES.match(c[0])]
    chosen = preferred[0] if preferred else candidates[0]

    name, host_port, internal_port, engine = chosen
    target.container = name
    target.host_port = host_port
    target.internal_port = internal_port
    target.engine = engine
    target.url = f"http://localhost:{host_port}"

    # Check for truly different containers (not just multiple ports on same container)
    unique_containers = set(c[0] for c in candidates)
    if len(unique_containers) > 1:
        target.health = "multiple"
    else:
        target.health = "serving"

    # Step 4: probe /v1/models, with the engine's API key once it asks for one (Strata 0.2+ answers
    # nothing but /health without it; engine_auth.py)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await get_with_engine_key(client, f"{target.url}/v1/models", target.container)
            if resp.status_code == 200:
                data = resp.json().get("data", [])
                if data:
                    target.model = data[0].get("id", "")
                    if target.health == "multiple":
                        pass  # keep multiple
                    else:
                        target.health = "serving"
            elif resp.status_code == 401:
                pass  # it answers but refuses our key: reachable, model unknown (not "unreachable")
            else:
                target.health = "unreachable"
    except Exception:
        target.health = "unreachable"

    # Step 5: GPU info
    target.gpus = await get_gpu_info()

    return target


_GPU_BASE_FIELDS = (
    "index,utilization.gpu,memory.used,memory.total,power.draw,power.limit,temperature.gpu"
)

# #1813 — the clock fields, newest spelling first.  nvidia-smi rejects a WHOLE
# query that names one field it doesn't know ('Field "…" is not a valid field to
# query.', on stdout, exit 2, no rows at all), so the clocks can't simply be
# appended: on an older driver that would blank every GPU card.  Each set is tried
# in order and the bare base query is always last, so the worst case is today's
# card without a clock.  ``clocks_throttle_reasons.*`` is the pre-R535 name of
# ``clocks_event_reasons.*``; 610.x accepts both.
_GPU_QUERY_SETS: tuple[tuple[str, ...], ...] = (
    ("clocks.sm", "clocks.max.sm", "clocks_event_reasons.active"),
    ("clocks.sm", "clocks.max.sm", "clocks_throttle_reasons.active"),
    ("clocks.sm", "clocks.max.sm"),
    (),
)

# Indices into _GPU_QUERY_SETS that this nvidia-smi has REJECTED as invalid
# fields.  Remembered so a rig on an old driver doesn't spawn nvidia-smi three
# times on every repaint.  Only the explicit "not a valid field" answer is cached;
# a transient failure (driver busy, timeout) is retried next poll.
_GPU_QUERY_REJECTED: set[int] = set()

# clocks_event_reasons bits (nvidia-smi --help-query-gpu; NVML
# nvmlClocksEventReason*).  Idle (0x1), the application-clocks setting (0x2),
# sync boost (0x10) and the display-clock setting (0x100) are deliberately NOT
# tagged — they aren't the card holding itself back under load.
_CLOCK_EVENT_IDLE = 0x01      # gpu_idle
_CLOCK_EVENT_TAGS: tuple[tuple[int, str], ...] = (
    (0x04, "power cap"),      # sw_power_cap
    (0x20, "thermal"),        # sw_thermal_slowdown
    (0x40, "thermal"),        # hw_thermal_slowdown
    (0x80, "power brake"),    # hw_power_brake_slowdown
    (0x08, "hw slowdown"),    # hw_slowdown (thermal OR power — NVML can't say which)
)


def throttle_tag(reasons: Optional[int], busy: bool = True) -> str:
    """The short tag for an active clock-event bitmask ("" = nothing to flag).

    ``power cap`` / ``thermal`` are the two that matter on a 3090 rig (#1813);
    several active reasons join with ", " in a fixed order.  An idle card gets
    no tag — the idle bit (0x1) set, or ``busy=False`` (the caller passes
    utilization > 0): its clock is low because nothing is running.  The driver
    can report sw_power_cap ALONE on an idle card for a sample (seen on 610.57:
    0x4 at 20 W / 210 MHz / 0 % util), and tagging that "power cap" would point
    at the wrong cause.
    """
    if not reasons or not busy or reasons & _CLOCK_EVENT_IDLE:
        return ""
    tags: list[str] = []
    for bit, tag in _CLOCK_EVENT_TAGS:
        if reasons & bit and tag not in tags:
            tags.append(tag)
    return ", ".join(tags)


def _opt_int(raw: str, base: int = 10) -> Optional[int]:
    """A reported number, or ``None`` for nvidia-smi's "[N/A]" / "[Not Supported]"."""
    raw = raw.strip()
    if not raw or raw.startswith("["):
        return None
    try:
        return int(raw, 16) if base == 16 else int(float(raw))
    except ValueError:
        return None


def _parse_gpu_rows(text: str, extra: tuple[str, ...]) -> list[GpuInfo]:
    """Parse ``--format=csv,noheader,nounits`` rows for the base fields + ``extra``.

    A row must carry exactly the requested column count — an error message
    ("Field … is not a valid field to query.") or a short row is not a GPU.  A
    base field that doesn't parse empties the whole read, as it always has; only
    the clock columns are optional.
    """
    want = 7 + len(extra)
    gpus: list[GpuInfo] = []
    for line in text.strip().split("\n"):
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != want:
            continue
        try:
            gpu = GpuInfo(
                index=int(parts[0]),
                utilization=int(float(parts[1])),
                mem_used_mib=int(float(parts[2])),
                mem_total_mib=int(float(parts[3])),
                power_draw_w=float(parts[4]),
                power_limit_w=float(parts[5]),
                temp_c=int(float(parts[6])),
            )
        except ValueError:
            return []
        for name, raw in zip(extra, parts[7:]):
            if name == "clocks.sm":
                gpu.clock_sm_mhz = _opt_int(raw)
            elif name == "clocks.max.sm":
                gpu.clock_max_sm_mhz = _opt_int(raw)
            elif name.endswith("_reasons.active"):
                gpu.clock_event_reasons = _opt_int(raw, base=16)
        gpus.append(gpu)
    return gpus


async def _query_gpus(extra: tuple[str, ...]) -> tuple[list[GpuInfo], bool]:
    """One nvidia-smi query → (rows, rejected-as-invalid-field).

    Raises on a spawn failure or timeout, so the caller stops instead of paying
    the timeout again for every fallback set.
    """
    fields = _GPU_BASE_FIELDS + "".join("," + f for f in extra)
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            "nvidia-smi",
            f"--query-gpu={fields}",
            "--format=csv,noheader,nounits",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
    except Exception:
        await _reap(proc)
        raise
    out = stdout.decode("utf-8", "replace") if isinstance(stdout, bytes) else ""
    err = stderr.decode("utf-8", "replace") if isinstance(stderr, bytes) else ""
    rejected = "not a valid field" in out or "not a valid field" in err
    return _parse_gpu_rows(out, extra), rejected


async def get_gpu_info() -> list[GpuInfo]:
    """Query nvidia-smi for GPU stats, with the SM clock where the driver has it.

    Falls back through ``_GPU_QUERY_SETS`` ONLY when nvidia-smi names a field as
    invalid; any other empty answer (no devices, a driver error) is the answer,
    exactly as before the clock fields existed — one spawn per poll.
    """
    try:
        for i, extra in enumerate(_GPU_QUERY_SETS):
            if i in _GPU_QUERY_REJECTED:
                continue
            gpus, rejected = await _query_gpus(extra)
            if gpus or not rejected or not extra:
                return gpus
            _GPU_QUERY_REJECTED.add(i)
        return []
    except Exception:
        return []


async def detect_from_registry(repo_root: str) -> list["VariantRow"]:
    """Enumerate registry variants via registry-emit.sh.

    Returns list[VariantRow] parsed from tab-delimited output.  This is a thin
    alias onto the converged parser in ``registry.py`` so there is exactly one
    tab parser + one ``VariantRow`` contract on the stack (the dict-returning
    duplicate that used to live here is gone).
    """
    from .registry import detect_from_registry_async
    return await detect_from_registry_async(repo_root)


def match_target_to_registry(target: ServingTarget, variants: list) -> ServingTarget:
    """Enrich a ServingTarget with registry metadata by matching container/port.

    Identity precedence — EXACT first.  A loose ``container in target.container``
    substring match shadows a real slug whose container name has a longer sibling:
    ``vllm-qwen36-27b-dual`` is a prefix of ``vllm-qwen36-27b-dual-max`` and
    ``beellama-carnice-v2`` of ``beellama-carnice-v2-dual``, so the shorter prefix
    would win and MISLABEL the serving model (and misdirect the targeted stop to a
    container that isn't running).  Resolve in order:
      1. EXACT container name (normalized ``_``→``-``) — the authoritative identity.
      2. EXACT host port.
      3. SUBSTRING container, LONGEST registry container first — last-resort for a
         docker project/scale suffix (``<name>-1``); longest-first so a prefix
         sibling can never shadow the real container.

    Match GRADE is recorded on ``target.match_confidence``:
      - ``"identity"`` — rule 1 (exact container).  The container IS this slug.
      - ``"shape"``    — rule 2/3 (port / substring fallback).  The slug is the
        best *shape* guess, NOT a verified identity: a brought model serving on
        a sibling's port (or a copied compose) lands here while actually running
        something else entirely — renderers must lead with the probed served-model
        id and present the slug as the matched shape (the Agents-A1 bring,
        2026-07-03, masqueraded as the 35B sibling through exactly this path).
      - ``""``         — unmatched (target returned unchanged).

    Accepts list[VariantRow] (core) or list[dict] (compat).
    """

    def _fields(v):
        if hasattr(v, "container"):
            return (v.container, v.port, v.slug, v.kvcalc_key, v.status, v.status_note)
        return (
            v.get("container", ""), v.get("port", 0), v.get("slug", ""),
            v.get("kvcalc_key", ""), v.get("status", ""), v.get("status_note", ""),
        )

    def _norm(c: str) -> str:
        return (c or "").replace("_", "-")

    def _apply(fields, confidence: str) -> ServingTarget:
        _container, _port, slug, kvcalc_key, status, status_note = fields
        target.slug = slug
        target.kv_format = kvcalc_key
        target.status = status
        target.status_note = status_note
        target.match_confidence = confidence
        return target

    rows = [_fields(v) for v in variants]
    tcont = _norm(target.container)

    # 1. EXACT container (normalized) — the running container IS this slug.
    if tcont:
        for f in rows:
            if _norm(f[0]) == tcont:
                return _apply(f, "identity")
    # 2. EXACT host port — a SHAPE guess (ports are copied between composes).
    if target.host_port:
        for f in rows:
            if f[1] == target.host_port:
                return _apply(f, "shape")
    # 3. SUBSTRING container, longest registry container first (never let a prefix
    #    sibling shadow the real one) — also a shape guess.
    if tcont:
        for f in sorted(rows, key=lambda r: len(_norm(r[0])), reverse=True):
            c = _norm(f[0])
            if c and c in tcont:
                return _apply(f, "shape")
    return target
