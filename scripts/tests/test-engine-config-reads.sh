#!/usr/bin/env bash
# Gate: does the pinned engine READ every key our launchers write into its config?
# (scripts/lib/profiles/engine_config_reads.py; evidence in engine-config-reads.json)
#
# THE CLASS THIS CATCHES. #1723 wrote Strata's MAX_TOKENS into the run config as `max_tokens`; Strata reads
# that key only in its vision encoder class, so the setting did nothing, and every gate passed:
# test-launch-knobs proves a value reaches the container, not that the engine uses it. Measured 2026-10-17:
# MAX_TOKENS=64, and a request without max_tokens of its own ran 1,514 tokens.
#
#   1. selftest: the checks against synthetic sources (a key read only in Vision.__init__ fails, --spec
#      fails when --help lists only --spec-min-p, ...): the positive and negative controls, every run;
#   2. check (no docker): the real launcher code, run once per setting, writes only keys with evidence;
#      no evidence is stale; the evidence was verified on the image the engine profile pins NOW;
#   3. verify, per engine whose pinned image is local: the server source and --help out of that image.
#      ⚠️ An image that isn't local can't be checked: the skip is printed, never silent, and step 2 still
#      holds the pin to the last verified one, so a pin bump stays red until someone runs
#      `verify <engine> --record` on the new image.
# Not covered (engine_config_reads.py says why): values, and settings handed to the engine's setup.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
export PYTHONDONTWRITEBYTECODE=1   # the launcher folders are mounted into the containers: leave no __pycache__
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
T="scripts/lib/profiles/engine_config_reads.py"

rc=0
echo "== 1. selftest"
python3 "$T" selftest || rc=1
echo "== 2. check: what the launchers write has evidence, on the pinned image"
python3 "$T" check || rc=1
echo "== 3. verify: the evidence, in each pinned image"
if ! command -v docker >/dev/null 2>&1; then
  echo "  ⊘ docker unavailable: image checks skipped (step 2 still holds each pin to its verified image)"
else
  for e in $(python3 "$T" engines); do
    pin="$(python3 "$T" pin "$e")"
    if docker image inspect "$pin" >/dev/null 2>&1; then
      python3 "$T" verify "$e" || rc=1
    else
      echo "  ⊘ $e: $pin not pulled here: its image check skipped (step 2 still holds the pin to the verified one)"
    fi
  done
fi

if [[ "$rc" -eq 0 ]]; then echo "test-engine-config-reads: ok"; else echo "test-engine-config-reads: FAILED" >&2; fi
exit "$rc"
