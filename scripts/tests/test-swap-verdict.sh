#!/usr/bin/env bash
# test-swap-verdict — scripts/lib/capture.sh's swap check tells pages SITTING in swap from pages
# being SWAPPED IN during the run (#1846). A server that barely fits its host keeps a few hundred MB of
# cold pages in swap for good, and the old check failed every such run ("every number is suspect")
# though nothing was paging; a host that IS paging (#1827: decode -11%) must still fail.
#
#   1. no serving-process pages in swap → PASS (at the start and at the end)
#   2. the start line states what is in swap and judges nothing (no PASS / WARN / FAIL)
#   3. pages in swap, little swapped in during the run → WARN ("cold pages, not paging")
#   4. pages in swap, a lot swapped in → FAIL ("it was paging")
#   5. SWAP_IN_FAIL_MB moves the line; no start mark → the old FAIL (nothing to judge against)
#
# Hermetic: CAP_PROC_STATUS / CAP_VMSTAT stand in for /proc/<pid>/status and /proc/vmstat.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"   # #779
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/capture.sh
source "$ROOT_DIR/scripts/lib/capture.sh"
CAP_PID=4242 CAP_WORK="$TMP/work"; mkdir -p "$CAP_WORK"
export CAP_PROC_STATUS="$TMP/status" CAP_VMSTAT="$TMP/vmstat"
page=$(getconf PAGESIZE 2>/dev/null || echo 4096)
status() { printf 'Name:\tpython3\nVmRSS:\t90000000 kB\nVmSwap:\t%s kB\n' "$1" > "$CAP_PROC_STATUS"; }
vmstat() { printf 'pgpgin 1\npswpin %s\npswpout 9\n' "$1" > "$CAP_VMSTAT"; }

status 0; vmstat 1000
[[ "$(cap_swap_verdict "" start)" == "PASS (no serving-process pages in swap)" ]] || fail "start, nothing in swap"
cap_swapin_mark
[[ "$(cap_swap_verdict)" == "PASS (no serving-process pages in swap)" ]] || fail "end, nothing in swap"
ok "nothing in swap: PASS at the start and at the end"

status 401336; vmstat 1000; rm -f "$CAP_WORK/pswpin0"
got="$(cap_swap_verdict "" start)"
[[ "$got" == "401336 kB of the SERVING PROCESS is in swap; the end of the run judges it by what is swapped back in" ]] \
  || fail "start line with pages in swap: $got"
[[ "$got" != PASS* && "$got" != WARN* && "$got" != FAIL* ]] || fail "the start line must not judge: $got"
ok "the start line states what is in swap and judges nothing"

cap_swapin_mark; vmstat $(( 1000 + 1500 ))   # ~50 swap-ins a request over a bench (#1846's run)
got="$(cap_swap_verdict)"
[[ "$got" == "WARN — 401336 kB of the SERVING PROCESS sits in swap, but the host swapped in only $(( 1500 * page / 1000000 )) MB during the run (limit 64 MB, SWAP_IN_FAIL_MB): cold pages, not paging" ]] \
  || fail "cold pages: $got"
ok "cold pages (1,500 swap-ins): WARN"

vmstat $(( 1000 + 400000 ))   # ~1.6 GB swapped back in: the host is paging
got="$(cap_swap_verdict)"
[[ "$got" == FAIL*"swapped in $(( 400000 * page / 1000000 )) MB during the run: it was paging; every number in this run is suspect" ]] \
  || fail "paging: $got"
ok "paging (400,000 swap-ins): FAIL"

vmstat $(( 1000 + 1500 ))
[[ "$(SWAP_IN_FAIL_MB=1 cap_swap_verdict)" == FAIL*"it was paging"* ]] || fail "SWAP_IN_FAIL_MB=1 must fail 6 MB"
rm -f "$CAP_WORK/pswpin0"
[[ "$(cap_swap_verdict)" == "FAIL — 401336 kB of the SERVING PROCESS is paged out to swap; every number in this run is suspect" ]] \
  || fail "no start mark: the old verdict"
ok "SWAP_IN_FAIL_MB moves the line; no start mark keeps the old FAIL"

# bench.sh takes the start line, then the mark, then judges at the end
src="$(cat "$ROOT_DIR/scripts/bench.sh")"
[[ "$src" == *'cap_swap_verdict "" start'*'cap_swapin_mark'*'swap check   : $(cap_swap_verdict'* ]] \
  || fail "bench.sh must print the start line, then mark, then judge at the end"
ok "bench.sh: start line → mark → end verdict"
echo "PASS test-swap-verdict"
