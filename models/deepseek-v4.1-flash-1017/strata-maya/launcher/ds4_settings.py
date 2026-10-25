#!/usr/bin/env python3
"""club-3090's launch settings for DeepSeek-V4.1-Flash-1017 on Project Maya, as ds4_prepare.py writes them into the
run config at every boot.

The same rules as the GLM recipe's maya_settings.py (models/glm-5.3-flash/strata-maya/launcher/), with DeepSeek's
own defaults: one serve/server.py reads the same run-config keys for both engines (frontend.py's effort_kwargs /
deepseek_effort_kwargs). ds4_prepare.py rewrites the config at each start, so a setting removed is gone at the next
boot. Maya's serve/server.py (the strata-maya-club3090 image) reads:

  setting                config key            Maya's own rule
  REASONING_EFFORT       reasoning_effort      none | low | high | max (frontend.py EFFORT: medium is high, xhigh is
                                               max); DeepSeek's template turns low / high / max into its 1-100
                                               "Reasoning Effort" budget. club default high, as Maya's own setup
                                               writes it for DeepSeek (maya.py DS4_EFFORT)
  ENABLE_THINKING=false  reasoning_effort      none: the template answers in chat mode (wins over REASONING_EFFORT)
  THINKING_BUDGET        thinking_budget       tokens, 0 = none; unset = Maya's own
  TEMP TOP_P             sampling.temperature  >= 0 / 0 < x <= 1; club defaults 1.0 / 1.0 (DeepSeek's own sampling,
                                               maya.py DS4_SAMPLING)
  TOP_K MIN_P            sampling.top_k        integer 1..64 / 0..1
  PRESENCE_PENALTY       sampling.presence_penalty   >= 0
  REPEAT_PENALTY         sampling.repetition_penalty > 0 (1 = off)
  SERVED_NAME            model_name            the name /v1/models reports; unset = deepseek-v4.1-flash. One name,
                                               no spaces
  THREADS                args: --cpu-threads   the CPU lane's threads (the experts VRAM doesn't hold are computed
                                               there, from RAM); whole number >= 1. Unset: 3/4 of the CPUs this
                                               container may use, at most one a physical core (threads(), below)

KV is not one of them: maya-ds4 has no --kv (its latent cache is fp16). Nor SPEC_N: DSpark's block length comes from
the pack's geometry (ds4.txt dspark_block_size), and maya-ds4 has no depth flag.

A new setting here needs its key's evidence in scripts/lib/profiles/engine-config-reads.json (where the pinned
server reads it): test-maya-ds4-config fails until it has some.

  ds4_settings.py validate     check the settings in the environment; exit 2 with the reason on a bad one
Python stdlib only, no Maya import: the launch-knob guard runs `validate` on the host.
"""
import os
import sys

DEFAULT_EFFORT = "high"
DEFAULT_SAMPLING = {"temperature": 1.0, "top_p": 1.0}      # DeepSeek's own, as Maya's setup writes it
DEFAULT_NAME = "deepseek-v4.1-flash"
EFFORTS = {"none": "none", "low": "low", "medium": "high", "high": "high", "xhigh": "max", "max": "max"}


class Bad(ValueError):
    pass


def _env(name):
    v = os.environ.get(name, "")
    return v if v != "" else None


def _int(name, v, lo, hi=None):
    if not v.isdigit():
        raise Bad(f"{name}={v!r}: expected a whole number")
    n = int(v)
    if n < lo or (hi is not None and n > hi):
        raise Bad(f"{name}={v!r}: expected {lo}..{hi}" if hi is not None else f"{name}={v!r}: expected >= {lo}")
    return n


def _float(name, v, ok, rule):
    try:
        x = float(v)
    except ValueError:
        raise Bad(f"{name}={v!r}: expected a number ({rule})") from None
    if not ok(x):
        raise Bad(f"{name}={v!r}: expected {rule}")
    return x


def _cpus():
    """The CPUs this process may use (its affinity: a container's or taskset's share)."""
    try:
        return sorted(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return list(range(os.cpu_count() or 1))


def _physical_cores(cpus, sysfs="/sys/devices/system/cpu"):
    """How many physical cores those CPUs sit on (SMT siblings counted once), or None when sysfs can't say."""
    cores = set()
    for c in cpus:
        try:
            with open(f"{sysfs}/cpu{c}/topology/core_id", encoding="ascii") as f:
                core = f.read().strip()
            with open(f"{sysfs}/cpu{c}/topology/physical_package_id", encoding="ascii") as f:
                pkg = f.read().strip()
        except OSError:
            return None
        cores.add((pkg, core))
    return len(cores) or None


def threads(cpus=None, physical=None):
    """The CPU lane's default thread count: 3/4 of the usable CPUs, at most one a physical core, at least 1.
    Leaving it to the engine (one a core, ~30 on a 32-core host) left the engine's other threads none and cost
    ~40% of decode on the reference rig; 3/4 of 32 cores = 24 was its measured best (16 / 28 / 30 were slower).
    The physical-core cap keeps an SMT desktop (16 cores, 32 threads) at 16 rather than oversubscribing to 24."""
    cpus = _cpus() if cpus is None else cpus
    n = max(1, round(len(cpus) * 3 / 4))
    if physical is None:
        physical = _physical_cores(cpus)
    return max(1, min(n, physical)) if physical else n


def settings():
    """(config keys to set, sampling block, extra engine args, notes) from the environment, checked."""
    keys, notes, args = {}, [], []
    effort = _env("REASONING_EFFORT")
    if effort is not None and effort not in EFFORTS:
        raise Bad(f"REASONING_EFFORT={effort!r}: expected none, low, high, max (or medium / xhigh, which Maya runs "
                  f"as high / max)")
    keys["reasoning_effort"] = EFFORTS[effort] if effort is not None else DEFAULT_EFFORT
    thinking = _env("ENABLE_THINKING")
    if thinking is not None:
        if thinking not in ("true", "false"):
            raise Bad(f"ENABLE_THINKING={thinking!r}: expected true or false")
        if thinking == "false":
            if effort is not None and EFFORTS[effort] != "none":
                notes.append(f"ENABLE_THINKING=false wins over REASONING_EFFORT={effort}: thinking off")
            keys["reasoning_effort"] = "none"
    budget = _env("THINKING_BUDGET")
    if budget is not None:
        keys["thinking_budget"] = _int("THINKING_BUDGET", budget, 0)
    sampling = dict(DEFAULT_SAMPLING)
    for name, key, ok, rule in (
            ("TEMP", "temperature", lambda x: x >= 0, ">= 0 (0 = greedy)"),
            ("TOP_P", "top_p", lambda x: 0 < x <= 1, "0 < top_p <= 1"),
            ("MIN_P", "min_p", lambda x: 0 <= x <= 1, "0 <= min_p <= 1"),
            ("PRESENCE_PENALTY", "presence_penalty", lambda x: x >= 0, ">= 0"),
            ("REPEAT_PENALTY", "repetition_penalty", lambda x: x > 0, "> 0 (1 = off)")):
        v = _env(name)
        if v is not None:
            sampling[key] = _float(name, v, ok, rule)
    top_k = _env("TOP_K")
    if top_k is not None:
        sampling["top_k"] = _int("TOP_K", top_k, 1, 64)
    served = _env("SERVED_NAME")
    if served is not None:
        if any(c.isspace() for c in served):
            raise Bad(f"SERVED_NAME={served!r}: expected one name, without spaces")
        keys["model_name"] = served
    n = _env("THREADS")
    if n is not None:
        args += ["--cpu-threads", str(_int("THREADS", n, 1))]
    else:
        n = threads()
        args += ["--cpu-threads", str(n)]
        notes.append(f"CPU lane: {n} threads (3/4 of the CPUs, at most one a physical core; THREADS sets it)")
    return keys, sampling, args, notes


def main(argv):
    if argv[1:] == ["validate"]:
        try:
            settings()
        except Bad as e:
            print(f"[maya-recipe] {e}", file=sys.stderr)
            return 2
        return 0
    print("usage: ds4_settings.py validate", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
