#!/usr/bin/env bash
# Test for switch.sh down_running() closed-world teardown (orphan cleanup).
#
# Contract: switch.sh tears down ONLY containers it manages — i.e. whose name
# is in the registry-derived VARIANT_CONTAINER set — via each container's own
# compose file WITH --remove-orphans. Anything not in that set (the services
# stack, estate instances with distinct ESTATE_CONTAINER names, unrelated user
# containers) is left strictly alone.
#
# Validates:
#   1. A managed vLLM container is torn down.
#   2. A managed ik-llama container is torn down (the bug: old RUNNING_PATTERN
#      ^(vllm-|llama-cpp-) missed ik-llama-/sglang-/beellama-).
#   3. An unrelated container (not in the managed set) is left alone.
#   4. A services-stack container (litellm) is left alone.
#   5. Teardown passes --remove-orphans.
#   6. When only unmanaged containers run, nothing is torn down and the
#      "no club-3090 container running" path is taken.
#   7. #1515: config_files is COMMA-JOINED for a container that came up with two -f
#      (every launch since #1498 adds the club3090.slug label override). Teardown passes
#      one -f per file — the whole string as one -f is a path that doesn't exist, and
#      every teardown fell back to `docker stop`.
#   8. A file that is gone by teardown time (the override, after the data dir moved) is
#      dropped, and the compose down still runs.
#   9. With no compose file left at all (a removed worktree, a renamed compose), the
#      container's project is brought down by its label alone (`compose -p <project> down`,
#      from an empty dir, COMPOSE_FILE unset). `docker stop` used to leave the container and
#      its network behind; it stays the last resort when there is no project label.
#  10. A managed container that is NOT running (crashed, exited, never started) is torn
#      down too, after its log is saved to <data dir>/logs/stopped-containers/ (newest 10
#      kept). Skipping it kept its network forever, and after a `docker network prune` the
#      next launch of that slug failed with "network ... not found". If the log can't be
#      saved, the container is left as it is. A stopped container we don't manage is
#      never touched.
#
# Harness: extract down_running() via sed, source it, inject a VARIANT_CONTAINER
# managed set + a mock `docker` on PATH that records compose-down / stop calls.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PASS=0
FAIL=0
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label}: expected output to CONTAIN: ${needle}" >&2
    echo "--- teardown log ---" >&2
    printf '%s\n' "$haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label}: expected output to NOT contain: ${needle}" >&2
    echo "--- teardown log ---" >&2
    printf '%s\n' "$haystack" >&2
    FAIL=$((FAIL + 1))
  fi
}

# --- Extract the function under test (avoids running switch.sh's main) --------
HELPERS_FILE="$(mktemp --suffix=.sh)"
sed -n '/^_save_stopped_container_log()/,/^}/p; /^_teardown_by_project()/,/^}/p; /^down_running()/,/^}/p' \
  scripts/switch.sh > "$HELPERS_FILE"
# shellcheck source=../lib/club-config.sh
source scripts/lib/club-config.sh          # club_config_data_dir, as switch.sh has it

tmp_dir="$(mktemp -d)"
cleanup() { rm -rf "$tmp_dir" "$HELPERS_FILE"; }
trap cleanup EXIT

# --- Mock `docker`: records compose-down / stop to $DOCKER_MOCK_LOG -----------
# Labels are returned non-empty so the compose-down branch is taken; the
# config_files label embeds the container name so the log identifies which
# container was brought down.
cat > "${tmp_dir}/docker" <<'EOF'
#!/usr/bin/env bash
sub="$1"; shift || true
case "$sub" in
  ps)
    # DOCKER_MOCK_RUNNING: names; DOCKER_MOCK_STOPPED: name:Status pairs, `_` for a space
    # (listed only with -a). {{.Status}} is what real docker prints: "Up 2 hours", "Exited (1) …".
    all=0; fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -a|--all) all=1; shift ;; --format) fmt="$2"; shift 2 || true ;; *) shift ;; esac
    done
    row() { if [[ "$fmt" == *Status* ]]; then printf '%s\t%s\n' "$1" "${2//_/ }"; else printf '%s\n' "$1"; fi; }
    for n in $DOCKER_MOCK_RUNNING; do row "$n" "Up_2_hours"; done
    if [[ $all -eq 1 ]]; then
      for p in ${DOCKER_MOCK_STOPPED:-}; do row "${p%%:*}" "${p#*:}"; done
    fi
    ;;
  inspect)
    fmt=""; cname=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) fmt="$2"; shift 2 || true ;;
        *) cname="$1"; shift ;;
      esac
    done
    if [[ "$fmt" == *working_dir* ]]; then
      printf '%s\n' "$DOCKER_MOCK_WORKDIR"
    elif [[ "$fmt" == *config_files* ]]; then
      printf '%s\n' "${DOCKER_MOCK_CONFIG_FILES:-compose-${cname}.yml}"
    elif [[ "$fmt" == *'compose.project"'* ]]; then
      printf '%s\n' "${DOCKER_MOCK_PROJECT-proj-${cname}}"
    elif [[ "$fmt" == *FinishedAt* ]]; then
      printf '%s\n' "2026-10-16T12:03:04.123456789Z"
    fi
    ;;
  logs)
    cname="${!#}"
    printf 'LOGS %s\n' "$cname" >> "$DOCKER_MOCK_LOG"
    [[ "${DOCKER_MOCK_LOGS_FAIL:-0}" == 1 ]] && exit 1
    printf 'LOG-OF-%s\n' "$cname"
    ;;
  stop)
    printf 'STOP %s\n' "$1" >> "$DOCKER_MOCK_LOG"
    ;;
  compose)
    # Record where it ran and whether a COMPOSE_FILE could have been read in.
    printf 'COMPOSE %s [cwd-entries=%s COMPOSE_FILE=%s]\n' "$*" "$(ls -A | wc -l)" "${COMPOSE_FILE-unset}" >> "$DOCKER_MOCK_LOG"
    ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "${tmp_dir}/docker"

export DOCKER_MOCK_LOG="${tmp_dir}/calls.log"
export DOCKER_MOCK_WORKDIR="${tmp_dir}"   # real dir so (cd "$lbl_dir") succeeds
export PATH="${tmp_dir}:$PATH"
export COMPOSE_BIN="docker compose"
export CLUB3090_DATA_DIR="${tmp_dir}/data-home"   # saved logs land here, never in your real data dir

# Managed set, as derive_switch_variant_tables would populate it (default
# container names, ESTATE_CONTAINER unwrapped). Spans all engine prefixes.
declare -A VARIANT_CONTAINER=(
  ["vllm/default"]="vllm-qwen36-27b"
  ["vllm/dual"]="vllm-qwen36-27b-dual"
  ["ik-llama/iq4ks-mtp"]="ik-llama-qwen36-27b"
  ["beellama/dflash"]="beellama-qwen36-27b"
  ["llamacpp/default"]="llama-cpp-qwen36-27b"
)

# The compose files a label names exist on a real rig; teardown now skips a missing one.
touch "${tmp_dir}/compose-vllm-qwen36-27b.yml" "${tmp_dir}/compose-ik-llama-qwen36-27b.yml"

# shellcheck source=/dev/null
source "$HELPERS_FILE"

# --- Scenario 1: mixed managed + unmanaged containers running -----------------
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_RUNNING="vllm-qwen36-27b unrelated-db ik-llama-qwen36-27b litellm"
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"

assert_contains     "$log" "compose-vllm-qwen36-27b.yml"     "managed vLLM container torn down"
assert_contains     "$log" "compose-ik-llama-qwen36-27b.yml" "managed ik-llama container torn down (the bug)"
assert_not_contains "$log" "unrelated-db"                    "unrelated container left alone"
assert_not_contains "$log" "litellm"                         "services-stack container left alone"
assert_contains     "$log" "--remove-orphans"                "teardown passes --remove-orphans"

# --- Scenario 2: only unmanaged containers running ----------------------------
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_RUNNING="litellm openwebui some-db"
out="$( set +u; down_running 2>&1 )" || true
log="$(cat "$DOCKER_MOCK_LOG")"

assert_not_contains "$log" "COMPOSE"                          "nothing torn down when only unmanaged running"
assert_not_contains "$log" "STOP"                             "nothing stopped when only unmanaged running"
assert_contains     "$out" "no club-3090 container running"   "reports no managed container running"

# --- Scenario 3 (#1515): a two-file, comma-joined config_files label -----------
mkdir -p "${tmp_dir}/data/compose-labels"
main="${tmp_dir}/mtp.yml"; override="${tmp_dir}/data/compose-labels/vllm-qwen36-27b.yml"
touch "$main" "$override"
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_RUNNING="vllm-qwen36-27b"
export DOCKER_MOCK_CONFIG_FILES="${main},${override}"
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_contains     "$log" "COMPOSE -f ${main} -f ${override} down --remove-orphans" "two-file label: one -f per file, then down (#1515)"
assert_not_contains "$log" "${main},${override}"              "two-file label: never passed as one comma-joined -f"
assert_not_contains "$log" "STOP"                              "two-file label: compose down ran, no stop fallback"

# --- Scenario 4: the label override is gone by teardown time -------------------
rm -f "$override"
: > "$DOCKER_MOCK_LOG"
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_contains     "$log" "COMPOSE -f ${main} down --remove-orphans" "missing override dropped, compose down still runs"
assert_not_contains "$log" "STOP"                              "missing override: no stop fallback"

# --- Scenario 5: no file left at all -> compose down by the project label --------
rm -f "$main"
: > "$DOCKER_MOCK_LOG"
export COMPOSE_FILE="${tmp_dir}/must-not-be-read.yml"   # a user's own COMPOSE_FILE must not leak in
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_contains     "$log" "COMPOSE -p proj-vllm-qwen36-27b down --remove-orphans" "no compose file left: down by project label"
assert_contains     "$log" "cwd-entries=0 COMPOSE_FILE=unset" "project down runs in an empty dir with COMPOSE_FILE unset"
assert_not_contains "$log" "STOP"                              "no compose file left: no docker stop (it left the network behind)"
unset COMPOSE_FILE

# --- Scenario 6: no file and no project label -> docker stop, the last resort ----
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_PROJECT=""
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_not_contains "$log" "COMPOSE"                           "no file, no project label: compose not called"
assert_contains     "$log" "STOP vllm-qwen36-27b"              "no file, no project label: docker stop"
unset DOCKER_MOCK_PROJECT DOCKER_MOCK_CONFIG_FILES

# --- Scenario 7: a STOPPED managed container is torn down, its log saved first ---
logdir="${CLUB3090_DATA_DIR}/logs/stopped-containers"
mkdir -p "$logdir"
for i in $(seq 1 12); do touch -d "2026-01-01 00:00:$(printf '%02d' "$i")" "${logdir}/old-${i}.log"; done
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_RUNNING="litellm"
export DOCKER_MOCK_STOPPED="vllm-qwen36-27b:Exited_(1)_3_minutes_ago user-db:Exited_(0)_2_days_ago"
out="$( set +u; down_running 2>&1 )" || true
log="$(cat "$DOCKER_MOCK_LOG")"
saved="${logdir}/vllm-qwen36-27b-20261016T120304.log"
assert_contains     "$log" "LOGS vllm-qwen36-27b"              "stopped managed: its log is read"
assert_contains     "$(cat "$saved" 2>/dev/null)" "LOG-OF-vllm-qwen36-27b" "stopped managed: log saved to the data dir"
assert_contains     "$out" "$saved"                            "stopped managed: says where the log went"
assert_contains     "$log" "compose-vllm-qwen36-27b.yml down --remove-orphans" "stopped managed: compose down (frees its network)"
assert_not_contains "$log" "user-db"                           "stopped container we don't manage: untouched"
assert_not_contains "$out" "no club-3090 container running"    "stopped managed counts as brought down"
n_logs="$(find "$logdir" -name '*.log' | wc -l)"
if [[ "$n_logs" -eq 10 && -f "$saved" && ! -e "${logdir}/old-1.log" ]]; then PASS=$((PASS + 1)); else
  echo "FAIL: saved logs: expected the newest 10 kept (incl. the new one), got ${n_logs}" >&2; FAIL=$((FAIL + 1)); fi

# --- Scenario 8: its log can't be saved -> the stopped container is kept --------
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_LOGS_FAIL=1
out="$( set +u; down_running 2>&1 )" || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_not_contains "$log" "COMPOSE"                           "log not saved: no compose down"
assert_not_contains "$log" "STOP"                              "log not saved: no stop"
assert_contains     "$out" "could not be saved"                "log not saved: says it kept the container"
unset DOCKER_MOCK_LOGS_FAIL DOCKER_MOCK_STOPPED

# --- Scenario 9: a container that never started ("created") is torn down too ----
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_STOPPED="ik-llama-qwen36-27b:Created"
( set +u; down_running ) >/dev/null 2>&1 || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_contains     "$log" "compose-ik-llama-qwen36-27b.yml down --remove-orphans" "never-started managed container torn down"

# --- Scenario 10: a crash-looping (Restarting) one is brought down like a running one -
: > "$DOCKER_MOCK_LOG"
export DOCKER_MOCK_STOPPED="ik-llama-qwen36-27b:Restarting_(1)_5_seconds_ago"
out="$( set +u; down_running 2>&1 )" || true
log="$(cat "$DOCKER_MOCK_LOG")"
assert_contains     "$out" "bringing down: ik-llama-qwen36-27b" "restarting: brought down as a running container"
assert_not_contains "$log" "LOGS ik-llama-qwen36-27b"           "restarting: no log save (it isn't stopped)"
unset DOCKER_MOCK_STOPPED

# --- Summary ------------------------------------------------------------------
echo "----------------------------------------"
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: switch.sh closed-world teardown"
