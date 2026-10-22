#!/usr/bin/env bash
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
#
# scripts/lib/strata-log.sh finds Project Maya's engine log in a Strata-kind container, so
# report.sh and verify-stress.sh read it instead of Strata's paths. #1706 and #1752 both pasted
# "tail: cannot open '/opt/strata/strata-*.log'" where Maya's engine log should have been.
#
#   1. Maya layout (/data/maya-{s,m,l}/maya.log): the NEWEST one is the answer
#   2. Strata layout (no maya.log): nothing, so the callers keep Strata's own tail
#   3. no container / "none" / a failing docker: nothing, exit 0, docker not even asked
#   4. report.sh and verify-stress.sh source the lib, ask it, and keep Strata's tail as the
#      fallback unchanged
#
# The stub docker runs the lib's REAL in-container command with /data/ pointed at a temp
# tree, so what is tested is the command a container would run. No GPU, no real container.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "ASSERTION FAILED: $*" >&2; exit 1; }
ok() { echo "  ok  $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/maya" "$TMP/strata"
export STUB_CALLS="$TMP/calls"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
[[ "${STUB_FAIL:-0}" == "1" ]] && exit 1
[[ "$1" == "exec" && "$3" == "sh" && "$4" == "-c" ]] || exit 1
exec sh -c "${5//\/data\//$STUB_DATA/}"
SH
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

# shellcheck source=../lib/strata-log.sh
source "${ROOT_DIR}/scripts/lib/strata-log.sh"

# --- 1. Maya: the newest maya.log wins -------------------------------------------------
for q in maya-s maya-m maya-l; do mkdir -p "$TMP/maya/$q"; echo "$q engine log" > "$TMP/maya/$q/maya.log"; done
touch -d '2026-10-20 10:00' "$TMP/maya/maya-s/maya.log"
touch -d '2026-10-21 10:00' "$TMP/maya/maya-l/maya.log"
touch -d '2026-10-22 10:00' "$TMP/maya/maya-m/maya.log"   # the running server's
got="$(STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-glm53-flash-dual-maya-m)"
[[ "$got" == "$TMP/maya/maya-m/maya.log" ]] || fail "Maya layout: got '$got', want the newest (maya-m)"
touch -d '2026-10-23 10:00' "$TMP/maya/maya-s/maya.log"
got="$(STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-glm53-flash-single-maya-s)"
[[ "$got" == "$TMP/maya/maya-s/maya.log" ]] || fail "Maya layout: newest moved to maya-s, got '$got'"
ok "Maya: the newest /data/*/maya.log is the one returned"

# --- 2. Strata: no maya.log, nothing returned ----------------------------------------
mkdir -p "$TMP/strata/state/strata/launch" "$TMP/strata/Strata-data"
echo "strata engine log" > "$TMP/strata/state/strata/launch/iq3_s.engine.log"
got="$(STUB_DATA="$TMP/strata" strata_maya_log_path strata-qwen38-flash-next-iq3s)"
[[ -z "$got" ]] || fail "Strata layout: got '$got', want nothing"
ok "Strata: nothing returned, so the callers keep Strata's own tail"

# --- 3. no container, none, failing docker -----------------------------------------
: > "$STUB_CALLS"
[[ -z "$(strata_maya_log_path "")" && -z "$(strata_maya_log_path none)" ]] || fail "no container should return nothing"
[[ ! -s "$STUB_CALLS" ]] || fail "docker was called without a container: $(cat "$STUB_CALLS")"
got="$(STUB_FAIL=1 STUB_DATA="$TMP/maya" strata_maya_log_path some-container)" || fail "a failing docker made the lib fail"
[[ -z "$got" ]] || fail "a failing docker returned '$got'"
ok "no container / none / a failing docker: nothing, exit 0"

# --- 4. the callers ------------------------------------------------------------------
for f in scripts/report.sh scripts/verify-stress.sh; do
  src="${ROOT_DIR}/${f}"
  command grep -q 'scripts/lib/strata-log.sh"' "$src" || fail "$f does not source scripts/lib/strata-log.sh"
  command grep -q 'strata_maya_log_path "\$CONTAINER"' "$src" || fail "$f does not ask strata_maya_log_path"
  command grep -qF '/data/state/strata/launch/*.engine.log /opt/strata/strata-*.log 2>/dev/null' "$src" \
    || fail "$f lost Strata's own tail (the fallback when there is no maya.log)"
done
ok "report.sh and verify-stress.sh ask the lib and keep Strata's tail as the fallback"

echo "PASS test-strata-log"
