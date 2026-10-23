"""The engine's API key for our own requests to it: Strata 0.2+ answers nothing but /health without one.

The decision lives in the repo's ``scripts/lib/engine-auth.sh`` (ENGINE_API_KEY, else a Strata container's own
API_KEY, else STRATA_API_KEY; nothing for a container without a key), the same helper every script uses.
This runs it directly with asyncio, never through a logged runner, so the key never lands in a run log, and
only after a request came back 401: engines without a key never pay for it. The key is cached per container
and fetched again on the next 401 (a recreated container may carry a new one).
"""
from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any, Optional

# tools/tui-core/club3090_tui_core/engine_auth.py -> the repo root (an editable install, as c3's is)
_REPO_ROOT = Path(__file__).resolve().parents[3]
_cache: dict[str, str] = {}


def auth_headers(key: str) -> dict:
    return {"Authorization": f"Bearer {key}"} if key else {}


async def engine_api_key(container: str, *, repo_root: Optional[str | Path] = None) -> str:
    """The key that applies to ``container`` (ENGINE_API_KEY first), or "" when none does or it can't be read."""
    explicit = os.environ.get("ENGINE_API_KEY", "")
    if explicit:
        return explicit
    if not container or container == "none":
        return ""
    lib = Path(repo_root or _REPO_ROOT) / "scripts" / "lib" / "engine-auth.sh"
    if not lib.is_file():
        return ""
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", "-c", 'source "$1"; club_engine_api_key "$2"', "engine-auth", str(lib), container,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        key = out.decode("utf-8", "replace").strip()
    except Exception:
        key = ""
    _cache[container] = key
    return key


async def get_with_engine_key(client: Any, url: str, container: str, *,
                              repo_root: Optional[str | Path] = None) -> Any:
    """``client.get(url)``, with the engine's key once the engine has asked for one (a 401)."""
    key = os.environ.get("ENGINE_API_KEY", "") or _cache.get(container, "")
    resp = await client.get(url, headers=auth_headers(key))
    if getattr(resp, "status_code", None) == 401 and container:
        fresh = await engine_api_key(container, repo_root=repo_root)
        if fresh and fresh != key:
            resp = await client.get(url, headers=auth_headers(fresh))
    return resp
