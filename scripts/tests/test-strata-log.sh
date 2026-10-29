#!/usr/bin/env bash
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
#
# scripts/lib/strata-log.sh finds Project Maya's engine log in a Strata-kind container, so
# report.sh and verify-stress.sh read it instead of Strata's paths. #1706 and #1752 both pasted
# "tail: cannot open '/opt/strata/strata-*.log'" where Maya's engine log should have been.
#
#   1. Maya layout (/data/maya-{s,m,l}/maya.log): with no run config to read, the NEWEST one is the answer
#   1b. the fallback also finds DeepSeek's maya-ds4.log and MiniMax's maya-mm3.log (#1845 found it
#      handing a DeepSeek container GLM's stale maya.log)
#   1c. the run config the server's command line names (--config) wins: its `log` is the server's own
#      log even when another engine's log on the shared /data is newer; one that names a missing
#      file falls back to the newest
#   2. Strata layout (no Maya log): nothing, so the callers keep Strata's own tail
#   3. no container / "none" / a failing docker: nothing, exit 0, docker not even asked
#   4. report.sh and verify-stress.sh source the lib, ask it, and keep Strata's tail as the
#      fallback unchanged
#
# The stub docker runs the lib's REAL in-container command with /data/ pointed at a temp
# tree and /proc/1/cmdline at STUB_CMDLINE (none: no file), so what is tested is the command a
# container would run. No GPU, no real container.

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
cmd="${5//\/data\//$STUB_DATA/}"
exec sh -c "${cmd//\/proc\/1\/cmdline/${STUB_CMDLINE:-/nonexistent/cmdline}}"
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

# --- 1b. the fallback finds DeepSeek's and MiniMax's logs too ------------------------
mkdir -p "$TMP/maya/ista-iq2-xxs" "$TMP/maya/minimax-maya-s"
echo "ds4 engine log" > "$TMP/maya/ista-iq2-xxs/maya-ds4.log"
echo "mm3 engine log" > "$TMP/maya/minimax-maya-s/maya-mm3.log"
touch -d '2026-10-24 10:00' "$TMP/maya/ista-iq2-xxs/maya-ds4.log"
touch -d '2026-10-25 10:00' "$TMP/maya/minimax-maya-s/maya-mm3.log"
got="$(STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-minimax31-flash-dual-maya-s)"
[[ "$got" == "$TMP/maya/minimax-maya-s/maya-mm3.log" ]] || fail "fallback: got '$got', want the newest log of any engine (maya-mm3)"
touch -d '2026-10-26 10:00' "$TMP/maya/ista-iq2-xxs/maya-ds4.log"
got="$(STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-deepseek41-flash-dual-ista-iq2-xxs)"
[[ "$got" == "$TMP/maya/ista-iq2-xxs/maya-ds4.log" ]] || fail "fallback: got '$got', want the newest (maya-ds4)"
ok "fallback: the newest maya.log / maya-ds4.log / maya-mm3.log is the one returned"

# --- 1c. the run config the server's command line names wins -------------------------
# A Maya container's process 1 once the entrypoint has exec'd the server (as read from a live DeepSeek
# container, 2026-10-29), and the
# config the launcher wrote (one "log" key: maya_prepare.py / the DeepSeek and MiniMax recipes)
printf '/opt/maya/.venv/bin/python\0/opt/maya/serve/server.py\0--engine\0strata\0--config\0%s\0--host\0000.0.0.0\0--port\08080\0' "$TMP/maya/ista-iq2-xxs/maya-ds4.json" > "$TMP/cmdline"
printf '{\n  "engine": "maya-ds4",\n  "log": "%s",\n  "args": ["--pack", "x"]\n}\n' "$TMP/maya/ista-iq2-xxs/maya-ds4.log" \
  > "$TMP/maya/ista-iq2-xxs/maya-ds4.json"
touch -d '2026-10-27 10:00' "$TMP/maya/maya-l/maya.log"   # GLM's log on the shared /data is NEWER (the #1845 case)
got="$(STUB_CMDLINE="$TMP/cmdline" STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-deepseek41-flash-dual-ista-iq2-xxs)"
[[ "$got" == "$TMP/maya/ista-iq2-xxs/maya-ds4.log" ]] || fail "run config: got '$got', want the config's log (maya-ds4), not the newest"
printf '{"engine": "maya-ds4", "log": "%s"}' "$TMP/maya/ista-iq2-xxs/gone.log" > "$TMP/maya/ista-iq2-xxs/maya-ds4.json"
got="$(STUB_CMDLINE="$TMP/cmdline" STUB_DATA="$TMP/maya" strata_maya_log_path strata-maya-deepseek41-flash-dual-ista-iq2-xxs)"
[[ "$got" == "$TMP/maya/maya-l/maya.log" ]] || fail "run config naming a missing log: got '$got', want the newest log"
ok "run config: its log wins over a newer one; a missing one falls back to the newest"

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
