"""engine_auth: our requests carry the engine's API key once the engine asks for one (Strata 0.2+).

The key comes from the repo's scripts/lib/engine-auth.sh, run with asyncio (stubbed here); a request is
first sent without it, so an engine with no key never pays for the lookup.
"""
from __future__ import annotations

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from club3090_tui_core import engine_auth
from club3090_tui_core.detect import detect_endpoint

KEY = "club-3090-strata-local-key"


def _run(coro):
    # pytest-asyncio isn't installed here: an `async def` test would be skipped, not run
    return asyncio.run(coro)


def _proc(out: str):
    mock = AsyncMock()
    mock.communicate = AsyncMock(return_value=(out.encode(), b""))
    return mock


class _Resp:
    def __init__(self, status: int, body=None):
        self.status_code = status
        self._body = body or {}

    def json(self):
        return self._body


class _Server:
    """A fake engine: 401 unless the request carries `Bearer <key>` (key=None: no key needed)."""

    def __init__(self, key=None, body=None):
        self.key, self.body, self.seen = key, body or {"data": [{"id": "qwen3.8-flash-next-iq3_s"}]}, []

    async def get(self, url, headers=None):
        auth = (headers or {}).get("Authorization", "")
        self.seen.append(auth)
        if self.key is None or auth == f"Bearer {self.key}":
            return _Resp(200, self.body)
        return _Resp(401)

    # as httpx.AsyncClient(...) is used: `async with ... as client`
    def __call__(self, *a, **k):
        return self

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    engine_auth._cache.clear()
    monkeypatch.delenv("ENGINE_API_KEY", raising=False)
    yield
    engine_auth._cache.clear()


def test_no_key_needed_no_lookup():
    srv = _Server(key=None)
    with patch("asyncio.create_subprocess_exec") as spawn:
        resp = _run(engine_auth.get_with_engine_key(srv, "http://x/v1/models", "vllm-qwen"))
    assert resp.status_code == 200 and srv.seen == [""]
    spawn.assert_not_called()


def test_401_fetches_the_key_and_retries_once_then_caches_it():
    srv = _Server(key=KEY)
    with patch("asyncio.create_subprocess_exec", return_value=_proc(KEY + "\n")) as spawn:
        resp = _run(engine_auth.get_with_engine_key(srv, "http://x/v1/models", "strata-x"))
        assert resp.status_code == 200 and srv.seen == ["", f"Bearer {KEY}"]
        # the helper is asked for this container only, through engine-auth.sh; the key is never an argument
        args = spawn.call_args.args
        assert args[:2] == ("bash", "-c") and args[-1] == "strata-x"
        assert args[-2].endswith("scripts/lib/engine-auth.sh") and KEY not in args
        resp = _run(engine_auth.get_with_engine_key(srv, "http://x/v1/models", "strata-x"))
    assert resp.status_code == 200 and srv.seen[2:] == [f"Bearer {KEY}"]   # cached: sent up front
    assert spawn.call_count == 1


def test_a_stale_cached_key_is_fetched_again():
    engine_auth._cache["strata-x"] = "an-old-key-0000000"
    srv = _Server(key=KEY)
    with patch("asyncio.create_subprocess_exec", return_value=_proc(KEY)):
        resp = _run(engine_auth.get_with_engine_key(srv, "http://x/v1/models", "strata-x"))
    assert resp.status_code == 200 and srv.seen == ["Bearer an-old-key-0000000", f"Bearer {KEY}"]


def test_no_key_available_no_retry():
    srv = _Server(key=KEY)
    with patch("asyncio.create_subprocess_exec", return_value=_proc("")):
        resp = _run(engine_auth.get_with_engine_key(srv, "http://x/v1/models", "strata-x"))
    assert resp.status_code == 401 and srv.seen == [""]


def test_engine_api_key_env_wins_and_is_sent_up_front(monkeypatch):
    monkeypatch.setenv("ENGINE_API_KEY", "explicit-key-000001")
    srv = _Server(key="explicit-key-000001")
    with patch("asyncio.create_subprocess_exec") as spawn:
        resp = _run(engine_auth.get_with_engine_key(srv, "http://remote/v1/models", ""))
    assert resp.status_code == 200 and srv.seen == ["Bearer explicit-key-000001"]
    spawn.assert_not_called()


def test_engine_api_key_without_the_helper_or_container(tmp_path: Path):
    with patch("asyncio.create_subprocess_exec") as spawn:
        assert _run(engine_auth.engine_api_key("strata-x", repo_root=tmp_path)) == ""   # no engine-auth.sh there
        assert _run(engine_auth.engine_api_key("")) == ""
        assert _run(engine_auth.engine_api_key("none")) == ""
    spawn.assert_not_called()


def test_engine_api_key_survives_a_failing_helper():
    with patch("asyncio.create_subprocess_exec", side_effect=OSError("no bash")):
        assert _run(engine_auth.engine_api_key("strata-x")) == ""


# detect_endpoint end to end: docker ps (stubbed) finds a Strata container, /v1/models is keyed
STRATA_PS = "strata-qwen38-flash-next-iq3s|0.0.0.0:8018->8080/tcp"


def _spawn(key: str):
    def side_effect(*args, **kwargs):
        return _proc(STRATA_PS) if args[0] == "docker" else _proc(key)
    return side_effect


def test_detect_reads_the_model_from_a_keyed_strata():
    srv = _Server(key=KEY)
    with patch("asyncio.create_subprocess_exec", side_effect=_spawn(KEY)), \
         patch("club3090_tui_core.detect.httpx.AsyncClient", srv), \
         patch("club3090_tui_core.detect.get_gpu_info", AsyncMock(return_value=[])):
        target = _run(detect_endpoint())
    assert target.container == "strata-qwen38-flash-next-iq3s"
    assert target.health == "serving" and target.model == "qwen3.8-flash-next-iq3_s"


def test_detect_401_without_a_key_is_reachable_not_unreachable():
    srv = _Server(key=KEY)
    with patch("asyncio.create_subprocess_exec", side_effect=_spawn("")), \
         patch("club3090_tui_core.detect.httpx.AsyncClient", srv), \
         patch("club3090_tui_core.detect.get_gpu_info", AsyncMock(return_value=[])):
        target = _run(detect_endpoint())
    assert target.health == "serving" and target.model == ""


def test_detect_other_errors_still_unreachable():
    class _Down(_Server):
        async def get(self, url, headers=None):
            return _Resp(503)
    with patch("asyncio.create_subprocess_exec", side_effect=_spawn("")), \
         patch("club3090_tui_core.detect.httpx.AsyncClient", _Down()), \
         patch("club3090_tui_core.detect.get_gpu_info", AsyncMock(return_value=[])):
        target = _run(detect_endpoint())
    assert target.health == "unreachable"
