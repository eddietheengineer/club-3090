#!/usr/bin/env python3
"""Apply club-3090's launch settings to Strata's run config at every boot (#1695 follow-up).

The entrypoint runs this inside the container (with the image's python) after setup. Strata reads
these keys from its config (serve/server.py in v0.1.45), but setup.py writes none of them, so a
setting only reached Strata if someone edited the JSON by hand:

  knob                   config key                    Strata's own rule (server.py v0.1.45)
  REASONING_EFFORT       reasoning_effort              none | low | medium | high (high = the template's xhigh)
  ENABLE_THINKING=false  reasoning_effort: none        thinking off for requests that don't ask for it
  THINKING_BUDGET        reasoning_budget_tokens       whole tokens, 0 = no budget
  SPEC_N                 args: --spec N                the MTP drafter's verify window (setup writes 4; 1..8)
  TEMP TOP_P TOP_K       sampling.temperature / top_p  >= 0 / 0 < x <= 1 / integer 1..64
  MIN_P                  sampling.min_p                0..1
  PRESENCE_PENALTY       sampling.presence_penalty     >= 0
  REPEAT_PENALTY         sampling.repetition_penalty   > 0 (1 = off)

MAX_TOKENS is not one of them: Strata reads no default output cap from the run config (its max_tokens
there is the vision encoder's, serve/runconfig.py doesn't list it); a default cap comes only from the
Chat settings its web page saves (POST /settings).

The live config is rebuilt from the copy setup wrote (<config>.setup.json) every time, so a
setting removed is a setting gone: nothing we wrote lingers. CONTEXT and KV belong to setup
itself (they size the KV and the expert cache), so `needs-setup` reports when they differ from
what setup was given and the entrypoint runs setup again.

  strata_config.py validate                      check the settings in the environment (exit 2 on a bad one)
  strata_config.py needs-setup <setup.json>      exit 0 (and say why) when CONTEXT / KV need a new setup
  strata_config.py apply <setup.json> <config>   write <config> = <setup.json> + the settings
"""
import json
import os
import sys

DEFAULT_CONTEXT = 131072          # the entrypoint's ${CONTEXT:-131072}
EFFORTS = {"none": "none", "low": "low", "medium": "medium", "high": "high",
           "xhigh": "high", "max": "high"}     # our other engines' names for Strata's "high" (the template's xhigh)
KV_FORMATS = ("fp16", "int8", "q4_0", "k8v4")  # the engine's --kv choices (strata --help, v0.1.45)


class Bad(ValueError):
    pass


def env(name):
    v = os.environ.get(name, "")
    return v if v != "" else None


def as_int(name, v, lo=None, hi=None):
    if not v.isdigit():
        raise Bad(f"{name}={v!r}: expected a whole number")
    n = int(v)
    if (lo is not None and n < lo) or (hi is not None and n > hi):
        rng = f"{lo}..{hi}" if hi is not None else f">= {lo}"
        raise Bad(f"{name}={v!r}: expected {rng}")
    return n


def as_float(name, v, ok, rule):
    try:
        x = float(v)
    except ValueError:
        raise Bad(f"{name}={v!r}: expected a number ({rule})") from None
    if not ok(x):
        raise Bad(f"{name}={v!r}: expected {rule}")
    return x


def settings():
    """The settings in the environment, checked: (config keys, sampling keys, spec, notes)."""
    keys, sampling, notes = {}, {}, []
    spec = None
    effort = env("REASONING_EFFORT")
    if effort is not None:
        if effort not in EFFORTS:
            raise Bad(f"REASONING_EFFORT={effort!r}: expected none, low, medium, high (or xhigh / max, "
                      f"which Strata runs as high)")
        keys["reasoning_effort"] = EFFORTS[effort]
    thinking = env("ENABLE_THINKING")
    if thinking is not None:
        if thinking not in ("true", "false"):
            raise Bad(f"ENABLE_THINKING={thinking!r}: expected true or false")
        if thinking == "false":
            if keys.get("reasoning_effort") not in (None, "none"):
                notes.append(f"ENABLE_THINKING=false wins over REASONING_EFFORT={effort}: thinking off")
            keys["reasoning_effort"] = "none"
    budget = env("THINKING_BUDGET")
    if budget is not None:
        keys["reasoning_budget_tokens"] = as_int("THINKING_BUDGET", budget, lo=0)
    spec_n = env("SPEC_N")
    if spec_n is not None:
        spec = as_int("SPEC_N", spec_n, lo=1, hi=8)
    for name, key, ok, rule in (
            ("TEMP", "temperature", lambda x: x >= 0, ">= 0 (0 = greedy)"),
            ("TOP_P", "top_p", lambda x: 0 < x <= 1, "0 < top_p <= 1"),
            ("MIN_P", "min_p", lambda x: 0 <= x <= 1, "0 <= min_p <= 1"),
            ("PRESENCE_PENALTY", "presence_penalty", lambda x: x >= 0, ">= 0"),
            ("REPEAT_PENALTY", "repetition_penalty", lambda x: x > 0, "> 0 (1 = off)")):
        v = env(name)
        if v is not None:
            sampling[key] = as_float(name, v, ok, rule)
    top_k = env("TOP_K")
    if top_k is not None:
        sampling["top_k"] = as_int("TOP_K", top_k, lo=1, hi=64)
    kv = env("KV")
    if kv is not None and kv not in KV_FORMATS:
        raise Bad(f"KV={kv!r}: expected one of {', '.join(KV_FORMATS)}")
    context = env("CONTEXT")
    if context is not None:
        as_int("CONTEXT", context, lo=4096)
    return keys, sampling, spec, notes


def arg_value(args, flag):
    return args[args.index(flag) + 1] if flag in args[:-1] else None


def needs_setup(setup_cfg):
    args = setup_cfg.get("args") or []
    want_ctx = int(env("CONTEXT") or DEFAULT_CONTEXT)
    have_ctx = arg_value(args, "--max-context")
    why = []
    if have_ctx is not None and int(have_ctx) != want_ctx:
        why.append(f"CONTEXT {have_ctx} -> {want_ctx}")
    kv = env("KV")
    have_kv = arg_value(args, "--kv")
    if kv is not None and kv != have_kv:
        why.append(f"KV {have_kv or '(setup default)'} -> {kv}")
    return why


def apply(setup_cfg):
    keys, sampling, spec, notes = settings()
    cfg = json.loads(json.dumps(setup_cfg))           # a deep copy: the setup copy is never touched
    cfg.update(keys)
    if sampling:
        cfg["sampling"] = {**(cfg.get("sampling") or {}), **sampling}
    if spec is not None:
        args = list(cfg.get("args") or [])
        if "--spec" in args[:-1]:
            args[args.index("--spec") + 1] = str(spec)
        else:
            args += ["--spec", str(spec)]
        cfg["args"] = args
    shown = [f"{k}={v}" for k, v in keys.items()] + [f"sampling.{k}={v}" for k, v in sampling.items()]
    if spec is not None:
        shown.append(f"--spec {spec}")
    return cfg, shown, notes


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    try:
        if cmd == "validate":
            settings()
            return 0
        if cmd == "needs-setup" and len(argv) == 3:
            why = needs_setup(json.load(open(argv[2], encoding="utf-8")))
            if why:
                print("[strata-recipe] setup again: " + "; ".join(why))
                return 0
            return 1
        if cmd == "apply" and len(argv) == 4:
            cfg, shown, notes = apply(json.load(open(argv[2], encoding="utf-8")))
            tmp = argv[3] + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=2)
            os.replace(tmp, argv[3])
            for n in notes:
                print(f"[strata-recipe] {n}")
            print("[strata-recipe] settings: " + (", ".join(shown) if shown else "none (Strata's defaults)"))
            return 0
    except Bad as e:
        print(f"[strata-recipe] {e}", file=sys.stderr)
        return 2
    print("usage: strata_config.py validate | needs-setup <setup.json> | apply <setup.json> <config>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
