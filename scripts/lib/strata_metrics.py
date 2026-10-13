#!/usr/bin/env python3
"""Read a Strata server's GET /metrics JSON: where our tools get Strata's runtime numbers.

Strata writes its per-request lines (throughput, drafts accepted, expert-cache hits) to a log
file inside the container, not to `docker logs`, so the log parsers the other engines use find
nothing there and would report a dead drafter or an empty run. /metrics carries the same numbers:
`totals` (cumulative since the server started), `requests` (the newest 12, newest first) and
`engine` (version, KV, expert slots). One reader, so every consumer reads them the same way.

  strata_metrics.py snapshot <base-url>                totals + engine as JSON on stdout
  strata_metrics.py delta <before.json> <after.json>   what happened between two snapshots
  strata_metrics.py recent <base-url> [N]              the newest N finished requests (default 12)

`delta` and `recent` print key=value lines:
  requests  output_tokens  decode_tok_s  prefill_tok_s  drafts_offered  drafts_accepted  accept_rate
`recent` adds hit_rate and the engine's version, kv, max_context and expert_slots. A value is
empty when there is nothing to divide by (no drafts offered: accept_rate is empty, not 0).

Exit 0 with the lines; 2 on bad usage; 3 when /metrics is unreachable, is not JSON, or is not
Strata's (no `engine.version` or `totals`). A consumer must report exit 3 as "could not read",
never as "no drafts" or "nothing ran". STRATA_API_KEY, when set, is sent as a bearer token
(Strata gates /metrics behind its API key when it has one). Standard library only.
"""
import json
import os
import sys
import urllib.error
import urllib.request

TIMEOUT_S = 10


def fail(msg, code=3):
    print(f"[strata-metrics] {msg}", file=sys.stderr)
    sys.exit(code)


def fetch(base):
    url = base.rstrip("/") + "/metrics"
    # Accept: application/json, because Strata answers text/plain with Prometheus text instead
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    key = os.environ.get("STRATA_API_KEY", "")
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            body = r.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as e:
        fail(f"{url}: {e}")
    return parse(body, url)


def parse(body, where):
    try:
        data = json.loads(body)
    except ValueError:
        fail(f"{where}: not JSON")
    if not isinstance(data, dict) or not isinstance(data.get("totals"), dict) \
            or not isinstance(data.get("engine"), dict) or not data["engine"].get("version"):
        fail(f"{where}: not a Strata /metrics document (no engine.version or totals)")
    return data


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def rate(n, ms):
    return f"{n * 1000.0 / ms:.2f}" if ms > 0 else ""


def figures(output_tokens, decode_ms, prompt_read, prompt_ms, offered, accepted, requests):
    return {
        "requests": str(int(requests)),
        "output_tokens": str(int(output_tokens)),
        "decode_tok_s": rate(output_tokens, decode_ms),
        "prefill_tok_s": rate(prompt_read, prompt_ms),
        "drafts_offered": str(int(offered)),
        "drafts_accepted": str(int(accepted)),
        "accept_rate": f"{accepted / offered:.4f}" if offered > 0 else "",
    }


def totals_figures(t, base=None):
    base = base or {}
    d = {k: num(t.get(k)) - num(base.get(k)) for k in
         ("requests", "output_tokens", "decode_ms", "prompt_tokens", "reused", "prompt_ms",
          "drafts_offered", "drafts_accepted")}
    return figures(d["output_tokens"], d["decode_ms"], d["prompt_tokens"] - d["reused"], d["prompt_ms"],
                   d["drafts_offered"], d["drafts_accepted"], d["requests"])


def emit(pairs):
    for k, v in pairs.items():
        print(f"{k}={v}")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("snapshot", "delta", "recent"):
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "snapshot":
        if len(argv) != 3:
            return main(argv[:1])
        data = fetch(argv[2])
        json.dump({"totals": data["totals"], "engine": data["engine"]}, sys.stdout)
        print()
        return 0
    if cmd == "delta":
        if len(argv) != 4:
            return main(argv[:1])
        snaps = []
        for path in argv[2:4]:
            try:
                with open(path, encoding="utf-8") as f:
                    snaps.append(parse(f.read(), path))
            except OSError as e:
                fail(f"{path}: {e}")
        before, after = snaps
        if num(after["totals"].get("requests")) < num(before["totals"].get("requests")):
            fail("the second snapshot has fewer requests than the first: the server restarted between them")
        emit(totals_figures(after["totals"], before["totals"]))
        return 0
    # recent
    if len(argv) not in (3, 4):
        return main(argv[:1])
    n = int(argv[3]) if len(argv) == 4 else 12
    data = fetch(argv[2])
    reqs = [r for r in (data.get("requests") or []) if isinstance(r, dict)][:max(n, 0)]
    out = figures(sum(num(r.get("output_tokens")) for r in reqs), sum(num(r.get("decode_ms")) for r in reqs),
                  sum(num(r.get("prompt_read")) for r in reqs), sum(num(r.get("prompt_ms")) for r in reqs),
                  sum(num(r.get("drafts_offered")) for r in reqs), sum(num(r.get("drafts_accepted")) for r in reqs),
                  len(reqs))
    hits = [num(r.get("hit_rate")) for r in reqs if r.get("hit_rate") is not None]
    out["hit_rate"] = f"{sum(hits) / len(hits):.3f}" if hits else ""
    eng = data["engine"]
    out.update(version=str(eng.get("version", "")), kv=str(eng.get("kv", "")),
               max_context=str(eng.get("max_context", "")), expert_slots=str(eng.get("expert_slots", "")))
    emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
