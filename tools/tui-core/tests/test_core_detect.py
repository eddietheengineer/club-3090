"""Tests for the core detection module."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from club3090_tui_core.detect import (
    ServingTarget,
    GpuInfo,
    PORT_MAP_BROAD_RE,
    PORT_MAP_ANY_RE,
    ENGINE_INTERNAL_PORTS,
    ENGINE_PREFIXES,
    _classify_engine,
    _classify_engine_from_container,
    _registry_claims,
    detect_endpoint,
    match_target_to_registry,
)
from club3090_tui_core.registry import VariantRow


# ============================================================================
# Test port regex
# ============================================================================

class TestPortRegex:
    def test_vllm_port(self):
        m = PORT_MAP_BROAD_RE.search("0.0.0.0:8010->8000/tcp")
        assert m is not None
        assert m.group(1) == "8010"
        assert m.group(2) == "8000"

    def test_llamacpp_port(self):
        m = PORT_MAP_BROAD_RE.search("0.0.0.0:8020->8080/tcp")
        assert m is not None
        assert m.group(1) == "8020"
        assert m.group(2) == "8080"

    def test_sglang_port(self):
        m = PORT_MAP_BROAD_RE.search("0.0.0.0:30000->30000/tcp")
        assert m is not None
        assert m.group(1) == "30000"
        assert m.group(2) == "30000"

    def test_ipv6_loopback(self):
        m = PORT_MAP_BROAD_RE.search("[::]:8011->8000/tcp")
        assert m is not None
        assert m.group(1) == "8011"

    def test_non_engine_port_ignored(self):
        m = PORT_MAP_BROAD_RE.search("0.0.0.0:8188->8188/tcp")
        assert m is None


# ============================================================================
# Test engine classification
# ============================================================================

class TestEngineClassification:
    def test_from_port(self):
        assert _classify_engine("8000") == "vllm"
        assert _classify_engine("8080") == "llamacpp"
        assert _classify_engine("30000") == "sglang"
        assert _classify_engine("9999") == "unknown"

    def test_from_container_name(self):
        assert _classify_engine_from_container("vllm-qwen36-27b") == "vllm"
        assert _classify_engine_from_container("llama-cpp-pi-reasoning") == "llamacpp"
        assert _classify_engine_from_container("ik-llama-cpp-dual") == "llamacpp"
        assert _classify_engine_from_container("sglang-main") == "sglang"
        assert _classify_engine_from_container("beellama-dflash") == "beellama"
        assert _classify_engine_from_container("random-container") == "unknown"


# ============================================================================
# Test ServingTarget
# ============================================================================

class TestServingTarget:
    def test_is_localhost(self):
        t = ServingTarget(url="http://localhost:8010")
        assert t.is_localhost is True

        t = ServingTarget(url="http://127.0.0.1:8010")
        assert t.is_localhost is True

        t = ServingTarget(url="http://192.168.1.50:8010")
        assert t.is_localhost is False

    def test_is_active(self):
        t = ServingTarget(url="http://localhost:8010", model="test-model", health="serving")
        assert t.is_active is True

        t = ServingTarget(url="http://localhost:8010", model="test-model", health="unreachable")
        assert t.is_active is False


# ============================================================================
# Test registry matching — with VariantRow objects (core path)
# ============================================================================

def _make_variant_row(**kwargs) -> VariantRow:
    defaults = dict(
        slug="vllm/dual",
        switch_engine="vllm",
        launch_engine="vllm",
        compose_dir="",
        file="",
        port=8010,
        model="qwen",
        engine="vllm",
        kvcalc_key="fp8",
        container="vllm_qwen",
        compose_path="",
        status="production",
        ctx_label="",
        status_note="",
    )
    defaults.update(kwargs)
    return VariantRow(**defaults)


class TestRegistryMatchingVariantRow:
    """match_target_to_registry with VariantRow objects."""

    def test_match_by_port(self):
        target = ServingTarget(host_port=8010, container="vllm-test")
        variants = [_make_variant_row(port=8010, slug="vllm/dual", status="production")]
        result = match_target_to_registry(target, variants)
        assert result.slug == "vllm/dual"
        assert result.status == "production"

    def test_match_by_container_name(self):
        target = ServingTarget(host_port=9999, container="vllm-qwen36-27b")
        variants = [_make_variant_row(container="vllm_qwen36_27b", port=8010, slug="vllm/dual")]
        result = match_target_to_registry(target, variants)
        assert result.slug == "vllm/dual"

    def test_no_match(self):
        target = ServingTarget(host_port=9999, container="unknown-thing")
        variants = [_make_variant_row(container="vllm_qwen", port=8010)]
        result = match_target_to_registry(target, variants)
        assert result.slug == ""

    def test_kvcalc_key_propagated(self):
        target = ServingTarget(host_port=8010)
        variants = [_make_variant_row(port=8010, kvcalc_key="qwen3.6-27b:fp8-mtp")]
        result = match_target_to_registry(target, variants)
        assert result.kv_format == "qwen3.6-27b:fp8-mtp"

    def test_status_note_propagated(self):
        target = ServingTarget(host_port=8010)
        variants = [_make_variant_row(port=8010, status_note="DFlash prose regression")]
        result = match_target_to_registry(target, variants)
        assert result.status_note == "DFlash prose regression"


class TestRegistryMatchingDictCompat:
    """match_target_to_registry with dict — backward-compat path."""

    def test_match_by_port_dict(self):
        target = ServingTarget(host_port=8010, container="vllm-test")
        variants = [
            {"slug": "vllm/dual", "port": 8010, "model": "qwen", "engine": "vllm",
             "kvcalc_key": "fp8", "status": "production", "container": "vllm_qwen",
             "compose_dir": "", "file": "", "switch_engine": "", "launch_engine": "",
             "compose_path": "", "ctx_label": "", "status_note": ""},
        ]
        result = match_target_to_registry(target, variants)
        assert result.slug == "vllm/dual"
        assert result.status == "production"

    def test_match_by_container_dict(self):
        target = ServingTarget(host_port=9999, container="vllm-qwen36-27b")
        variants = [
            {"slug": "vllm/dual", "port": 8010, "model": "qwen", "engine": "vllm",
             "kvcalc_key": "fp8", "status": "production", "container": "vllm_qwen36_27b",
             "compose_dir": "", "file": "", "switch_engine": "", "launch_engine": "",
             "compose_path": "", "ctx_label": "", "status_note": ""},
        ]
        result = match_target_to_registry(target, variants)
        assert result.slug == "vllm/dual"


class TestRegistryMatchExactNotPrefix:
    """Regression: a slug whose container name is a PREFIX of the actually-running
    container must NOT shadow the real one — the old substring match mislabelled
    ``vllm-...-dual-max`` as ``vllm/dual`` and ``...-carnice-v2-dual`` as the single
    (and then misdirected the targeted stop to a container that wasn't running)."""

    # registry order puts the shorter (prefix) container FIRST — the worst case.
    VARIANTS = [
        _make_variant_row(container="vllm-qwen36-27b-dual", port=8010, slug="vllm/dual"),
        _make_variant_row(container="vllm-qwen36-27b-dual-max", port=8013,
                          slug="vllm/qwen-27b-dual-max", status="experimental"),
        _make_variant_row(container="beellama-carnice-v2", port=8068,
                          slug="beellama/carnice-v2-single-q5km-mtp", status="experimental"),
        _make_variant_row(container="beellama-carnice-v2-dual", port=8070,
                          slug="beellama/carnice-v2-dual-q8-mtp", status="experimental"),
    ]

    def test_dual_max_not_shadowed_by_dual(self):
        target = ServingTarget(container="vllm-qwen36-27b-dual-max", host_port=8013)
        assert match_target_to_registry(target, self.VARIANTS).slug == "vllm/qwen-27b-dual-max"

    def test_carnice_dual_not_shadowed_by_single(self):
        target = ServingTarget(container="beellama-carnice-v2-dual", host_port=8070)
        assert (
            match_target_to_registry(target, self.VARIANTS).slug
            == "beellama/carnice-v2-dual-q8-mtp"
        )

    def test_prefix_slug_still_matches_its_own_container(self):
        target = ServingTarget(container="vllm-qwen36-27b-dual", host_port=8010)
        assert match_target_to_registry(target, self.VARIANTS).slug == "vllm/dual"

    def test_port_only_when_no_container(self):
        target = ServingTarget(container="", host_port=8013)
        assert match_target_to_registry(target, self.VARIANTS).slug == "vllm/qwen-27b-dual-max"

    def test_docker_scale_suffix_uses_longest_substring(self):
        # A docker project/scale suffix (<name>-1) has no exact match → pass 3
        # picks the LONGEST containing registry container, never a prefix sibling.
        target = ServingTarget(container="beellama-carnice-v2-dual-1", host_port=0)
        assert (
            match_target_to_registry(target, self.VARIANTS).slug
            == "beellama/carnice-v2-dual-q8-mtp"
        )


class TestMatchConfidence:
    """F9 (slug masquerade): the match GRADE is recorded on ``match_confidence``
    so renderers can distinguish a verified identity (exact container) from a
    shape guess (port/substring fallback).  Regression source: the Agents-A1
    bring (2026-07-03) served on a sibling's port and was PRESENTED as
    ``vllm/qwen-35b-a3b-dual`` with no hint it was a different model."""

    VARIANTS = [
        _make_variant_row(container="vllm-qwen36-35b-a3b-dual", port=8051,
                          slug="vllm/qwen-35b-a3b-dual"),
        _make_variant_row(container="vllm-qwen36-27b-dual", port=8010, slug="vllm/dual"),
    ]

    def test_exact_container_is_identity(self):
        target = ServingTarget(container="vllm-qwen36-27b-dual", host_port=8010)
        result = match_target_to_registry(target, self.VARIANTS)
        assert result.slug == "vllm/dual"
        assert result.match_confidence == "identity"

    def test_port_fallback_is_shape(self):
        # The A1 masquerade: an unknown (brought) container on a sibling's port
        # still slug-matches — but MUST be graded a shape guess, not an identity.
        target = ServingTarget(
            container="vllm-agents-a1-dual", host_port=8051, model="agents-a1"
        )
        result = match_target_to_registry(target, self.VARIANTS)
        assert result.slug == "vllm/qwen-35b-a3b-dual"
        assert result.match_confidence == "shape"

    def test_substring_fallback_is_shape(self):
        target = ServingTarget(container="vllm-qwen36-27b-dual-1", host_port=0)
        result = match_target_to_registry(target, self.VARIANTS)
        assert result.slug == "vllm/dual"
        assert result.match_confidence == "shape"

    def test_unmatched_is_empty(self):
        target = ServingTarget(container="comfyui", host_port=7861)
        result = match_target_to_registry(target, self.VARIANTS)
        assert result.slug == ""
        assert result.match_confidence == ""


# ============================================================================
# #1219 — detection is REGISTRY-FIRST, not container-name-prefix-first
# ============================================================================


def _row(slug, container, port, engine="vllm"):
    return VariantRow(
        slug=slug, switch_engine=engine, launch_engine=engine, compose_dir="d",
        file="f.yml", port=port, model="m", engine=engine, kvcalc_key="k",
        container=container, compose_path="p", status="production",
        ctx_label="32K", status_note="",
    )


def _proc(ps_output: str):
    """Stub for `docker ps --format {{.Names}}|{{.Ports}}`."""
    mock = AsyncMock()
    mock.communicate = AsyncMock(return_value=(ps_output.encode(), b""))
    return mock


def _run(coro):
    """Drive a coroutine without pytest-asyncio.

    ⚠️ pytest-asyncio is NOT installed for this package, so an ``async def`` test
    is SKIPPED, not run — a green line that proves nothing.  Baseline before these
    tests was "25 passed", with zero skips; anything that reports skips here is a
    test that silently did not execute.
    """
    return asyncio.run(coro)


# A local slug can satisfy NEITHER heuristic by construction: the container is
# named by whatever the user's compose calls it, and a third-party engine listens
# on whatever internal port it likes.  Both are true of the bucko recipe that
# surfaced this (2026-09-08).
LOCAL_PS = "qwen38-flash-next-ple|0.0.0.0:20272->9000/tcp"


class TestRegistryClaims:
    def test_builds_map_from_variant_rows(self):
        claims = _registry_claims([_row("x/y", "my-engine", 20272)])
        assert "my-engine" in claims
        assert claims["my-engine"][1] == 20272

    def test_normalizes_underscores(self):
        claims = _registry_claims([_row("x/y", "my_engine", 1)])
        assert "my-engine" in claims

    def test_ignores_rows_without_a_container(self):
        assert _registry_claims([_row("x/y", "", 1)]) == {}

    def test_accepts_dict_rows(self):
        claims = _registry_claims([{"container": "c", "port": 42}])
        assert claims["c"][1] == 42

    def test_empty_and_none(self):
        assert _registry_claims(None) == {}
        assert _registry_claims([]) == {}


class TestRegistryFirstDetection:
    """The bug: a registered container that matches neither heuristic is invisible."""

    def test_local_slug_invisible_without_registry(self):
        """Baseline — this is the reported failure, and it must stay reproducible."""
        with patch("asyncio.create_subprocess_exec", return_value=_proc(LOCAL_PS)):
            target = _run(detect_endpoint())
        assert target.health == "unreachable"
        assert not target.url

    def test_local_slug_detected_when_registry_claims_it(self):
        rows = [_row("bucko-vllm/flash-next", "qwen38-flash-next-ple", 20272)]
        with patch("asyncio.create_subprocess_exec", return_value=_proc(LOCAL_PS)):
            target = _run(detect_endpoint(variants=rows))
        assert target.container == "qwen38-flash-next-ple"
        assert target.host_port == 20272
        assert target.internal_port == 9000   # NOT one of the three curated ports
        # The reported symptom is an EMPTY target.url: with no url, health.sh
        # falls back to the curated default port and reports "not reachable" over
        # a plainly loaded model.  Resolving the url is the fix.
        assert target.url == "http://localhost:20272"
        # `health` stays "unreachable" here because nothing is actually listening
        # on 20272 in a unit test — that probe is Step 4 and is not what #1219 is
        # about.  Asserting on it would be asserting on the stub, not the fix.

    def test_engine_family_comes_from_the_registry_row(self):
        """Engine identity is lineage (the profile's type), not the container name."""
        rows = [_row("x/y", "qwen38-flash-next-ple", 20272, engine="vllm")]
        with patch("asyncio.create_subprocess_exec", return_value=_proc(LOCAL_PS)):
            target = _run(detect_endpoint(variants=rows))
        assert target.engine == "vllm"

    def test_unclaimed_non_engine_container_still_ignored(self):
        """Registry-first must not become 'accept everything'."""
        ps = "open-webui|0.0.0.0:8080->8080/tcp\nqdrant|0.0.0.0:6333->6333/tcp"
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            target = _run(detect_endpoint(variants=[_row("x/y", "not-running", 1)]))
        # open-webui publishes 8080->8080 and so still trips the port heuristic;
        # what matters is that qdrant (neither prefix nor engine port) never does.
        assert target.container != "qdrant"

    def test_heuristics_still_work_for_unregistered_containers(self):
        ps = "vllm-hand-run|0.0.0.0:8000->8000/tcp"
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            target = _run(detect_endpoint(variants=[]))
        assert target.container == "vllm-hand-run"
        assert target.engine == "vllm"

    def test_claimed_container_preferred_over_heuristic_match(self):
        ps = ("vllm-some-other|0.0.0.0:8000->8000/tcp\n"
              "qwen38-flash-next-ple|0.0.0.0:20272->9000/tcp")
        rows = [_row("bucko-vllm/flash-next", "qwen38-flash-next-ple", 20272)]
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            target = _run(detect_endpoint(variants=rows))
        assert target.container == "qwen38-flash-next-ple"

    def test_registry_host_port_wins_over_a_second_mapping(self):
        """An engine that also publishes metrics must resolve to its API port."""
        ps = "qwen38-flash-next-ple|0.0.0.0:9100->9100/tcp, 0.0.0.0:20272->9000/tcp"
        rows = [_row("x/y", "qwen38-flash-next-ple", 20272)]
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            target = _run(detect_endpoint(variants=rows))
        assert target.host_port == 20272

    def test_omitting_variants_is_unchanged_behaviour(self):
        ps = "vllm-qwen36-27b-minimal|0.0.0.0:8020->8000/tcp"
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            a = _run(detect_endpoint())
            b = _run(detect_endpoint(variants=None))
        assert a.container == b.container == "vllm-qwen36-27b-minimal"


class TestAnyPortRegex:
    def test_matches_arbitrary_internal_port(self):
        m = PORT_MAP_ANY_RE.search("0.0.0.0:20272->9000/tcp")
        assert m and m.group(1) == "20272" and m.group(2) == "9000"

    def test_broad_regex_still_rejects_arbitrary_internal_port(self):
        """The narrow regex must stay narrow — it gates UNCLAIMED containers."""
        assert not PORT_MAP_BROAD_RE.search("0.0.0.0:20272->9000/tcp")


class TestExllamav3Detection:
    """#1360: an exllamav3 (TabbyAPI) container was invisible to c3.

    TabbyAPI listens on 5000 inside the container and our composes name it
    ``tabbyapi-…``; neither was in the heuristic sets, so the Doctor tab — which
    detects without registry rows — and the cockpit's container list both skipped it.
    """

    TABBY_PS = "tabbyapi-qwen38-flash-next-exl3-405|0.0.0.0:8181->5000/tcp"

    def test_found_without_registry_rows(self):
        with patch("asyncio.create_subprocess_exec", return_value=_proc(self.TABBY_PS)):
            target = _run(detect_endpoint())
        assert target.container == "tabbyapi-qwen38-flash-next-exl3-405"
        assert target.host_port == 8181
        assert target.internal_port == 5000
        assert target.engine == "exllamav3"
        assert target.url == "http://localhost:8181"

    def test_unrelated_app_on_5000_still_ignored(self):
        """Negative control: 5000 is a common app port, so the port alone must not admit a container."""
        ps = "some-flask-app|0.0.0.0:5000->5000/tcp"
        with patch("asyncio.create_subprocess_exec", return_value=_proc(ps)):
            target = _run(detect_endpoint())
        assert target.container != "some-flask-app"
        assert not target.url

    def test_engine_classifiers(self):
        assert _classify_engine("5000") == "exllamav3"
        for name in ("tabbyapi-x", "exl3-x", "exllamav3-x"):
            assert _classify_engine_from_container(name) == "exllamav3"
        assert ENGINE_PREFIXES.match("tabbyapi-qwen38-flash-next-exl3-405")
        assert "5000" in ENGINE_INTERNAL_PORTS


class TestStrataDetection:
    """Strata serves on 8080 and answers /props like llama-server, so the port map
    alone reads it as llamacpp: its ``strata-`` container name has to win."""

    STRATA_PS = "strata-qwen38-flash-next-iq3s|0.0.0.0:20219->8080/tcp"

    def test_found_and_classified_by_name_not_port(self):
        with patch("asyncio.create_subprocess_exec", return_value=_proc(self.STRATA_PS)):
            target = _run(detect_endpoint())
        assert target.container == "strata-qwen38-flash-next-iq3s"
        assert target.internal_port == 8080
        assert target.engine == "strata"
        assert target.url == "http://localhost:20219"

    def test_engine_classifiers(self):
        assert _classify_engine_from_container("strata-x") == "strata"
        assert ENGINE_PREFIXES.match("strata-qwen38-flash-next-iq3s")
        # positive control for the trap: the same port, a llama.cpp name, still reads llamacpp
        assert _classify_engine_from_container("llama-cpp-x") == "llamacpp"
        assert _classify_engine("8080") == "llamacpp"


# ============================================================================
# #1813 — SM clock + throttle reason on the GPU read
# ============================================================================

import club3090_tui_core.detect as _detect  # noqa: E402
from club3090_tui_core.detect import get_gpu_info, throttle_tag  # noqa: E402

# Real 610.57 output shape for the full query (index … temperature.gpu,
# clocks.sm, clocks.max.sm, clocks_event_reasons.active).
SMI_CLOCKS = (
    "0, 99, 22000, 24576, 229.80, 230.00, 83, 1665, 2115, 0x0000000000000004\n"
    "1, 0, 1, 24576, 20.54, 230.00, 45, 210, 2100, 0x0000000000000001\n"
)
SMI_INVALID = 'Field "clocks_event_reasons.active" is not a valid field to query.\n\n'


def _smi(stdout: str):
    mock = AsyncMock()
    mock.communicate = AsyncMock(return_value=(stdout.encode(), b""))
    return mock


class _SmiStub:
    """Answers nvidia-smi by the fields it was asked for; records each query."""

    def __init__(self, answer):
        self.answer = answer
        self.queries: list[str] = []

    async def __call__(self, *argv, **_kw):
        q = next(a for a in argv if a.startswith("--query-gpu="))
        self.queries.append(q)
        return _smi(self.answer(q))


@pytest.fixture(autouse=False)
def fresh_gpu_query_cache():
    _detect._GPU_QUERY_REJECTED.clear()
    yield
    _detect._GPU_QUERY_REJECTED.clear()


@pytest.mark.usefixtures("fresh_gpu_query_cache")
class TestGpuClocks:
    def test_parses_clock_and_reasons(self):
        stub = _SmiStub(lambda q: SMI_CLOCKS)
        with patch("asyncio.create_subprocess_exec", stub):
            gpus = _run(get_gpu_info())
        assert [g.index for g in gpus] == [0, 1]
        assert gpus[0].clock_sm_mhz == 1665 and gpus[0].clock_max_sm_mhz == 2115
        assert gpus[0].clock_event_reasons == 0x4
        assert gpus[1].clock_event_reasons == 0x1
        assert gpus[0].power_draw_w == 229.8 and gpus[0].temp_c == 83  # base fields intact
        assert len(stub.queries) == 1
        assert "clocks.sm,clocks.max.sm,clocks_event_reasons.active" in stub.queries[0]

    def test_unreported_values_are_none_not_zero(self):
        row = "0, 5, 100, 24576, 30.0, 230.0, 40, [N/A], [Not Supported], [Not Supported]\n"
        with patch("asyncio.create_subprocess_exec", _SmiStub(lambda q: row)):
            (gpu,) = _run(get_gpu_info())
        assert gpu.clock_sm_mhz is None
        assert gpu.clock_max_sm_mhz is None
        assert gpu.clock_event_reasons is None
        assert gpu.mem_used_mib == 100

    def test_older_driver_falls_back_to_throttle_reasons_name(self):
        """A driver that rejects clocks_event_reasons (pre-R535 name) still gets clocks."""
        def answer(q):
            if "clocks_event_reasons" in q:
                return SMI_INVALID
            return SMI_CLOCKS.replace("0x0000000000000004", "0x0000000000000020")
        stub = _SmiStub(answer)
        with patch("asyncio.create_subprocess_exec", stub):
            gpus = _run(get_gpu_info())
            assert gpus[0].clock_event_reasons == 0x20
            assert "clocks_throttle_reasons.active" in stub.queries[1]
            # the rejection is remembered: the next poll spawns ONCE, not twice
            _run(get_gpu_info())
        assert len(stub.queries) == 3
        assert "clocks_event_reasons" not in stub.queries[2]

    def test_driver_without_any_clock_field_keeps_the_card(self):
        """Every clock field rejected → the bare base query, exactly today's card."""
        base_row = "0, 10, 2000, 24576, 100.0, 230.0, 60\n"

        def answer(q):
            if "clocks" in q:
                return 'Field "clocks.max.sm" is not a valid field to query.\n'
            return base_row
        stub = _SmiStub(answer)
        with patch("asyncio.create_subprocess_exec", stub):
            (gpu,) = _run(get_gpu_info())
        assert gpu.mem_used_mib == 2000
        assert gpu.clock_sm_mhz is None and gpu.clock_event_reasons is None
        assert len(stub.queries) == 4
        assert stub.queries[-1] == "--query-gpu=" + _detect._GPU_BASE_FIELDS

    def test_no_rows_without_a_rejection_is_one_spawn(self):
        """Negative control for the fallback: 'No devices were found' is the answer,
        not a reason to try three more queries."""
        stub = _SmiStub(lambda q: "No devices were found\n")
        with patch("asyncio.create_subprocess_exec", stub):
            assert _run(get_gpu_info()) == []
        assert len(stub.queries) == 1
        assert _detect._GPU_QUERY_REJECTED == set()

    def test_timeout_is_not_retried_per_fallback_set(self):
        calls = {"n": 0}

        async def hang(*_a, **_k):
            calls["n"] += 1
            raise asyncio.TimeoutError
        with patch("asyncio.create_subprocess_exec", hang):
            assert _run(get_gpu_info()) == []
        assert calls["n"] == 1

    def test_bad_base_field_still_empties_the_read(self):
        """Unchanged contract: an unparseable base column (here power.draw) → []."""
        row = "0, 5, 100, 24576, [N/A], 230.0, 40, 1500, 2100, 0x0000000000000000\n"
        with patch("asyncio.create_subprocess_exec", _SmiStub(lambda q: row)):
            assert _run(get_gpu_info()) == []


class TestThrottleTag:
    def test_power_cap_and_thermal(self):
        assert throttle_tag(0x04) == "power cap"
        assert throttle_tag(0x20) == "thermal"
        assert throttle_tag(0x40) == "thermal"
        assert throttle_tag(0x04 | 0x40) == "power cap, thermal"
        assert throttle_tag(0x20 | 0x40) == "thermal"  # one tag, not two

    def test_nothing_to_flag(self):
        assert throttle_tag(None) == ""
        assert throttle_tag(0) == ""
        assert throttle_tag(0x02) == ""   # applications clocks setting
        assert throttle_tag(0x10) == ""   # sync boost
        assert throttle_tag(0x100) == ""  # display clock setting

    def test_idle_card_gets_no_tag(self):
        assert throttle_tag(0x01) == ""
        assert throttle_tag(0x01 | 0x04) == ""
        # the 610.57 sample: sw_power_cap alone on an idle card
        assert throttle_tag(0x04, busy=False) == ""
        assert throttle_tag(0x04, busy=True) == "power cap"  # positive control
