#!/usr/bin/env bash
# test-bench-interconnect-qengine — bench.sh's interconnect block reports what QEngine says it chose
# (#1846). QEngine runs its own collectives and links no NCCL, so the vLLM / SGLang classifier found no
# evidence in its log. Its two libraries word it differently, and the block must not claim more than a
# line says:
#   1. layer 2 is n/a (no NCCL), never "no NCCL_P2P* in the serving environment"
#   2. the 27B (libqengine) with peer access: "P2P: decode all-reduce GPU to GPU", plus its prefill mode
#   3. Flash-Next (libqflash) with peer access prints no decode line: the block says it isn't stated
#   4. without peer access (both libraries' own format strings) and a refused pair: said, with a ⚠
#   5. CONTAINER=none: n/a, no log to read
# Hermetic: the function is extracted from bench.sh. The log reader is the real p2p_qengine_transport
# from lib/p2p-state.sh (report.sh reads QEngine through it too, #1862); the other p2p_* helpers and
# docker are stubs.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"   # #779
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^bench_interconnect_block()/,/^}/p' "$ROOT_DIR/scripts/bench.sh" > "$TMP/block.sh"
command grep -q 'QEngine runs its own collectives' "$TMP/block.sh" || fail "the QEngine branch is not in bench_interconnect_block"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  inspect) exit 0 ;;
  logs) printf '%b' "${QE_LOG:-}" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/docker"

block() {  # <container> <log> -> the block's output
  QE_LOG="$2" CONTAINER="$1" PATH="$TMP/bin:$PATH" bash -c '
    source "$2"
    p2p_gpu_count() { echo 2; }; p2p_host_capability() { echo pcie_p2p; }; p2p_driver_flavor() { echo open; }
    ENGINE_KIND=qengine; source "$1"; bench_interconnect_block' _ "$TMP/block.sh" "$ROOT_DIR/scripts/lib/p2p-state.sh" 2>&1
}

out="$(block qengine-qwen38-27b-dual 'P2P: decode all-reduce GPU to GPU (peer access between all 2 GPUs)\n[comm] prefill transfers: copy engine (QE_COMM=auto, auto)\n')"
[[ "$out" == *"layer 2  NCCL use         : n/a — QEngine runs its own collectives (no NCCL)"* ]] || fail "layer 2: $out"
[[ "$out" == *"layer 3  engine transport : decode all-reduce GPU to GPU (peer access); prefill transfers: copy engine (QE_COMM=auto)"* ]] \
  || fail "27B with peer access: $out"
[[ "$out" != *"engine custom-AR :"* && "$out" != *"NCCL_P2P"* ]] || fail "no vLLM / SGLang classifier row for QEngine: $out"
ok "27B with peer access: layer 2 n/a, decode GPU to GPU, prefill on the copy engine"

out="$(block qengine-qwen38-flash-next-dual '[comm] topology: numa -1,-1 (1 node), P2P rank 0-1:0\n[comm] prefill transfers: P2P SM loads / stores, pairs 1<-0:pull 0<-1:pull (FLASH_COMM=auto, auto: P2P tax 1.78 (cap 1.30, 1 NUMA node), CE tax 1.03, P2P 13 CE 13 host 9 GB/s)\n')"
[[ "$out" == *"layer 3  engine transport : decode path not stated in the log; prefill transfers: P2P SM loads / stores (FLASH_COMM=auto)"* ]] \
  || fail "Flash-Next with peer access: $out"
ok "Flash-Next with peer access: decode path not claimed, prefill P2P SM loads / stores"

out="$(block qengine-qwen38-27b-dual 'P2P: enabling peer access 0->1 failed (peer access is not supported between these two devices), host path\nQE_COMM: collectives through pinned host memory (no peer access)\n[comm] prefill transfers: host-staged (QE_COMM=auto, auto)\n')"
[[ "$out" == *"engine transport : no peer access: collectives through pinned host memory; prefill transfers: host-staged (QE_COMM=auto); ⚠ P2P: enabling peer access 0->1 failed"* ]] \
  || fail "27B without peer access: $out"
out="$(block qengine-qwen38-flash-next-dual '[flash] no peer access: attention exchanges through pinned host memory (slower than P2P)\n')"
[[ "$out" == *"engine transport : no peer access: collectives through pinned host memory"* ]] || fail "Flash-Next without peer access: $out"
ok "without peer access (both libraries) and a refused pair: said, with a ⚠"

out="$(block none 'P2P: decode all-reduce GPU to GPU (peer access between all 2 GPUs)\n')"
[[ "$out" == *"engine transport : n/a — no container to read QEngine's log from"* ]] || fail "CONTAINER=none: $out"
ok "CONTAINER=none: n/a"
echo "PASS test-bench-interconnect-qengine"
