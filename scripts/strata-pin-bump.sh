#!/usr/bin/env bash
# strata-pin-bump — move the strata or strata-maya engine pin to a new release in one command.
#
# The bump rule (which releases to take, which slug to boot, what never to skip) is in
# docs/NIGHTLY_BUMP_RUNBOOK.md, "Strata and Project Maya: the bump rule". This runs it:
#
#   1. pulls the release's image and pins its digest (Strata: upstream's `<release>-cuda13`;
#      Maya: our `:<vX.Y.Z>`, which build.sh --push must have published first: this never builds
#      or pushes);
#   2. checks in the new image what our launchers rely on (Strata: the `strata launch --kv`
#      choices, the --spec help, the entrypoint's settings; Maya: the quant names in maya.py) and
#      refuses when one changed;
#   3. edits every place the pin lives (engine-pin-bump.sh's spec + compose defaults, source_ref,
#      the engine profile's pin- lines, the docs/UPSTREAM.md row, Strata's "Pinned" line), each
#      target checked to match exactly once before anything is written;
#   4. re-records the settings evidence (engine_config_reads.py verify <engine> --record);
#   5. boots ONE slug through switch.sh, checks it runs the pinned digest, sends 3 warm-ups, runs
#      verify-full, reads free RAM and swap, and stops it;
#   6. prints a summary for the pin PR, with the upstream releases the bump skipped.
#
# Guards are not run here (they flake under GPU load): run Tier 0 + the pin guards afterwards.
#
# Usage:
#   scripts/strata-pin-bump.sh strata 0.2.3 --family ista|swift   # the family the notes touch
#   scripts/strata-pin-bump.sh strata 0.2.3 --slug <strata/... slug>
#   scripts/strata-pin-bump.sh strata-maya v1.1.25                 # boots the dual Maya-L slug
#   scripts/strata-pin-bump.sh <engine> <release> --check          # resolve + checks + planned diff; writes nothing
#   scripts/strata-pin-bump.sh <engine> <release> --no-boot        # edits + record, no boot
#
# Run it from a worktree on the pin branch (it refuses on master). READY_TIMEOUT (default 1800 s)
# bounds the boot. Exit: 0 done; 1 a check, the record or the boot failed; 2 refused, nothing written.
set -euo pipefail

# Force Python's UTF-8 mode (PEP 540) for every python3 this script runs: the files it edits are full
# of unicode (— × → …), and a rig on a non-UTF-8 locale would otherwise decode them with the locale
# codec (#779). Exported, so child processes inherit it. Guarded by test-locale-utf8.sh.
export PYTHONUTF8="${PYTHONUTF8:-1}"

case "${1:-}" in
  -h|--help|"") command grep -E '^#( |$)' "${BASH_SOURCE[0]}" | cut -c3-; [[ -n "${1:-}" ]] && exit 0; exit 2 ;;
esac
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/strata_pin_bump.py" "$@"
