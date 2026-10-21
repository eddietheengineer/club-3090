#!/usr/bin/env bash
# setup.sh <slug> must preserve that slug over a different engine's default (#1741).
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run the production hint block with two registry rows; no downloads or GPU.
sed -n '/^SAMPLE_CONTAINER=""/,$p' "$ROOT/scripts/setup.sh" > "$TMP/hint.sh"
mkdir -p "$TMP/scripts/lib"
cat > "$TMP/scripts/lib/registry-emit.sh" <<'EMIT'
cat <<'JSON'
{
  "variants": [
    {"slug": "llamacpp/qwen38-flash-next-dual", "model": "qwen3.8-flash-next",
     "status": "production", "container": "llama-default", "port": 8088,
     "served_name": "llama-default"},
    {"slug": "strata/qwen3.8-flash-next-iq3s-dual", "model": "qwen3.8-flash-next",
     "status": "incubating", "container": "strata-requested", "port": 8018,
     "served_name": "strata-requested"}
  ],
  "defaults": [{"model": "qwen3.8-flash-next", "slug": "llamacpp/qwen38-flash-next-dual"}]
}
JSON
EMIT
out="$(
  ROOT_DIR="$TMP"
  MODEL_NAME=qwen3.8-flash-next
  SETUP_SLUG=strata/qwen3.8-flash-next-iq3s-dual
  model_label() { echo "$1"; }
  source "$TMP/hint.sh"
)"
for expected in \
  'bash scripts/switch.sh --force strata/qwen3.8-flash-next-iq3s-dual' \
  'docker logs -f strata-requested' \
  'localhost:8018/v1/chat/completions' \
  '"model":"strata-requested"'; do
  [[ "$out" == *"$expected"* ]] || fail "missing '$expected' in: $out"
done
[[ "$out" != *llama-default* ]] || fail "hint used the model default: $out"
echo "test-setup-launch-hint: ok"
