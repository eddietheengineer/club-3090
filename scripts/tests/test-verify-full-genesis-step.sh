#!/usr/bin/env bash
#
# Guard: verify-full's step 2 tells "this container doesn't load Genesis" apart from
# "Genesis should have loaded but left no marker".
#
# Why this exists: no shipped compose has loaded Genesis since 2026-07-06, yet step 2 told
# every vLLM-family slug "no Genesis marker in logs (container restarted, or Genesis not
# loaded)", which reads like a fault (paulp83's bucko-vllm report, Discussion #1700). The
# step now reads the container's own mounts and environment: a container that mounts
# Genesis's patch tree or sets a GENESIS_* variable keeps the old message; one that does
# neither is "not applicable". A Genesis result in the log (applied / FAILED) still wins.
#
# This drives the REAL functions (check_patches and container_loads_genesis, extracted from
# scripts/verify-full.sh) with docker and the pass/fail/skip helpers stubbed.
#
# ⚠️ Against the pre-fix tree this test must FAIL (container_loads_genesis doesn't exist and
# the plain vLLM case gets the old message). If it passes there, it asserts the wrong thing.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"   # repo rule (#779); the fixtures name a python3 path

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
VF="${VERIFY_FULL:-${ROOT}/scripts/verify-full.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; printf "    expected=%s\n    got=%s\n" "$2" "$3"; FAIL=1; }
check() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

awk '/^check_patches\(\) \{/,/^\}/; /^container_loads_genesis\(\) \{/,/^\}/' "$VF" > "${TMP}/fns.sh"
for fn in check_patches container_loads_genesis; do
  if ! command grep -q "^${fn}() {" "${TMP}/fns.sh"; then
    bad "verify-full.sh defines ${fn}()" "a function body" "not found"
  fi
done
[[ "$FAIL" == 0 ]] || { echo "FAIL: test-verify-full-genesis-step"; exit 1; }

# docker stub: `inspect --format` prints the mounts/env fixture, `logs` the log fixture.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  inspect) [[ "${STUB_INSPECT_FAIL:-0}" == 1 ]] && exit 1; cat "$STUB_SPEC" ;;
  logs)    cat "$STUB_LOG" ;;
  *)       exit 1 ;;
esac
EOF
chmod +x "${TMP}/bin/docker"

# bucko-vllm's shape: the model dir, a patch dir, caches; env without GENESIS_*
printf '%s\n' "/srv/models /models" "/repo/patches/default-thinking-budget /etc/club3090/thinking-budget" \
  "PORT=8000" "CPU_OFFLOAD_GB=30" "VLLM_PLE_OFFLOAD_READY_TIMEOUT=1200" > "${TMP}/spec-plain"
# an archived Genesis compose: the _genesis overlay mount and its switches
printf '%s\n' "/repo/patches/genesis/vllm/_genesis /usr/local/lib/python3.12/dist-packages/vllm/_genesis" \
  "PORT=8000" > "${TMP}/spec-mount"
printf '%s\n' "/srv/models /models" "GENESIS_ENABLE_P64_QWEN3CODER_MTP_STREAMING=1" > "${TMP}/spec-env"
# a near miss that must NOT count: "genesis" inside an unrelated path or value
printf '%s\n' "/srv/genesis-notes /notes" "NOTE=see_genesis_docs" > "${TMP}/spec-nearmiss"
printf '%s\n' "INFO vLLM API server version 0.31.0" "INFO Started server process" > "${TMP}/log-none"
printf '%s\n' "[Genesis] applied: P64" "[Genesis] apply_all elapsed: 0.42 s" > "${TMP}/log-applied"

step2() {   # $1=spec fixture $2=log fixture [VAR=VAL ...] → "<pass|fail|skip>: <message>"
  local spec="$1" log="$2"; shift 2
  (
    source "${TMP}/fns.sh"
    pass() { echo "pass: $1"; }
    fail() { echo "fail: $1"; }
    skip() { echo "skip: $1"; }
    container_is_real() { return 0; }
    # shellcheck disable=SC2030
    export PATH="${TMP}/bin:${PATH}" STUB_SPEC="$spec" STUB_LOG="$log"
    ENGINE_KIND=vllm CONTAINER=c
    for kv in "$@"; do export "${kv?}"; done
    check_patches | command grep -v '^\[2/10\]'
  )
}

NA="skip: not applicable — this container doesn't load Genesis (no Genesis mount, no GENESIS_* setting)"
OLD="skip: no Genesis marker in logs (container restarted, or Genesis not loaded)"
check "plain vLLM container (bucko-vllm shape): not applicable" "$NA" "$(step2 "${TMP}/spec-plain" "${TMP}/log-none")"
check "a 'genesis' substring in an unrelated path or value doesn't count" "$NA" \
  "$(step2 "${TMP}/spec-nearmiss" "${TMP}/log-none")"
check "Genesis mounted, no marker: the old message" "$OLD" "$(step2 "${TMP}/spec-mount" "${TMP}/log-none")"
check "GENESIS_* set, no marker: the old message" "$OLD" "$(step2 "${TMP}/spec-env" "${TMP}/log-none")"
check "docker inspect fails: assume it might, keep the old message" "$OLD" \
  "$(step2 "${TMP}/spec-plain" "${TMP}/log-none" STUB_INSPECT_FAIL=1)"
check "a Genesis result in the log still wins on a plain container" \
  "pass: Genesis patches applied (apply_all completed clean)" "$(step2 "${TMP}/spec-plain" "${TMP}/log-applied")"

if [[ "$FAIL" == 0 ]]; then echo "PASS: test-verify-full-genesis-step"; else echo "FAIL: test-verify-full-genesis-step"; exit 1; fi
