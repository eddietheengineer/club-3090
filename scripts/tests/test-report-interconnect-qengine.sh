#!/usr/bin/env bash
# test-report-interconnect-qengine — report.sh's interconnect section says what QEngine chose (#1862).
# QEngine runs its own collectives and links no NCCL, so its log has none of the [nvlink] / all-reduce
# lines the shared classifier reads. report.sh then printed "P2P engagement undetermined" and a verdict
# that the container shows no P2P engagement, on a boot where bench.sh's interconnect block read
# "decode all-reduce GPU to GPU (peer access)" from the same log. Both now read QEngine through
# p2p_qengine_transport (lib/p2p-state.sh). Asserts:
#   1. a QEngine container: its own line (decode path + prefill mode), and an n/a verdict, never the
#      "undetermined" fallback or the shared engagement verdict
#   2. a QEngine log that states no decode path: said so, not guessed
#   3. negative control: a vLLM container with no evidence still gets the existing fallback
# Hermetic: the interconnect region is extracted from report.sh, p2p-state.sh is the real one, and
# docker and the GPU / host probes are stubs.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"   # #779
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
awk '/_p2p_class_stream="\$\(docker logs/ {on=1} /# Kernel-module flavor/ {on=0} on' \
  "$ROOT_DIR/scripts/report.sh" > "$TMP/region.sh"
command grep -q '\*\*Interconnect verdict:\*\*' "$TMP/region.sh" || fail "the interconnect region is not extractable from report.sh"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  logs) printf '%b' "${ENGINE_LOG:-}" ;;
  exec) exit 0 ;;
esac
exit 0
SH
chmod +x "$TMP/bin/docker"

region() {  # <engine kind> <container> <log> -> the section's output
  ENGINE_LOG="$3" PATH="$TMP/bin:$PATH" bash -c '
    source "$2"
    p2p_gpu_count() { echo 2; }; p2p_host_capability() { echo pcie_p2p; }
    ENGINE_KIND="$3" CONTAINER="$4"; source "$1"' _ "$TMP/region.sh" "$ROOT_DIR/scripts/lib/p2p-state.sh" "$1" "$2" 2>&1
}

out="$(region qengine qengine-qwen38-27b-dual 'P2P: decode all-reduce GPU to GPU (peer access between all 2 GPUs)\n[comm] prefill transfers: copy engine (QE_COMM=auto, auto)\n')"
[[ "$out" == *"QEngine runs its own collectives (no NCCL). Its log: decode all-reduce GPU to GPU (peer access); prefill transfers: copy engine (QE_COMM=auto)."* ]] \
  || fail "QEngine's own line: $out"
[[ "$out" == *"**Interconnect verdict:** ℹ driver P2P capability is reported above; QEngine runs its own collectives"* ]] \
  || fail "QEngine verdict: $out"
[[ "$out" != *"P2P engagement undetermined"* && "$out" != *"shows no P2P engagement signal"* ]] \
  || fail "QEngine fell through to the shared fallback or verdict: $out"
ok "QEngine: its own transport line and an n/a verdict, not 'undetermined'"

out="$(region qengine qengine-qwen38-flash-next-dual '[comm] prefill transfers: P2P SM loads / stores, pairs 1<-0:pull 0<-1:pull (FLASH_COMM=auto, auto: P2P tax 1.78)\n')"
[[ "$out" == *"Its log: decode path not stated in the log; prefill transfers: P2P SM loads / stores (FLASH_COMM=auto)."* ]] \
  || fail "Flash-Next, no decode line: $out"
ok "a QEngine log with no decode line: said so, not guessed"

out="$(region vllm vllm-qwen38-27b-dual 'INFO some unrelated line\n')"
[[ "$out" == *"P2P engagement undetermined"* ]] || fail "vLLM fallback changed: $out"
[[ "$out" != *"QEngine"* ]] || fail "QEngine text on a vLLM container: $out"
ok "negative control: a vLLM container with no evidence keeps the existing fallback"
echo "PASS test-report-interconnect-qengine"
