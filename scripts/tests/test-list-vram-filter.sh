#!/usr/bin/env bash
# `switch.sh --list` card-size filter.
#
# A compose whose header declares `Requires-min-vram-gb` above the smallest card
# this machine would use is hidden from `--list`, the rule launch.sh's picker
# already applies. `--list --all` shows it again, the header tallies what was
# hidden, and a note says why. Fail-open: cards that can't be read (no nvidia-smi,
# or a selector of GPU UUIDs) mean no card filter. Card sizes are faked with
# CLUB3090_FAKE_GPUS (compose-meta.sh) and the count with CUDA_VISIBLE_DEVICES,
# so the test doesn't depend on this host's GPUs.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)

# Force Python's UTF-8 mode (PEP 540) for every python3 this script runs.
# Repo sources are full of unicode (— × → ⚠), and without this a rig on a real
# non-UTF-8 locale (de_DE.iso88591 and friends) decodes reads, stdout AND argv
# with the locale codec, which crashes the launcher/emit paths (#779). Python
# already auto-enables UTF-8 mode for the C/POSIX locale, so this covers the
# case it does NOT: a genuine non-UTF-8, non-C locale. Exported, so child
# processes and nested scripts inherit it. Guarded by test-locale-utf8.sh.
export PYTHONUTF8="${PYTHONUTF8:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export MODEL_DIR="${MODEL_DIR:-/mnt/models/huggingface}"
# A per-model default pin makes the Defaults view name a slug; keep it out.
while IFS= read -r pin_key; do
  export "${pin_key}="
done < <(compgen -v | command grep '^CLUB3090_DEFAULT_' || true)

SWITCH="$ROOT_DIR/scripts/switch.sh"
fail=0
note() { echo "FAIL: $1" >&2; fail=1; }

# Fixtures from the registry, so a renamed slug can't silently void the test:
# a listed (functional-status) single-card slug that needs 32 GB cards, and one
# that declares 24 GB as the positive control.
read -r BIG_SLUG CTRL_SLUG < <(python3 - <<'PY'
import pathlib, re, yaml
entries = yaml.safe_load(open("scripts/lib/profiles/registry.yaml", encoding="utf-8"))["entries"]
need = {}
for slug, e in sorted(entries.items()):
    if e.get("status") in ("deprecated", "upstream-gated", "incubating"):
        continue
    p = pathlib.Path(e.get("compose_path", ""))
    if "/single/" not in str(p) or not p.is_file():
        continue
    m = re.search(r"^#\s*Requires-min-vram-gb:\s*(\d+)", p.read_text(encoding="utf-8"), re.M)
    if m:
        need.setdefault(int(m.group(1)), slug)
print(need.get(32, "MISSING"), need.get(24, "MISSING"))
PY
)
[[ "$BIG_SLUG" != MISSING && "$CTRL_SLUG" != MISSING ]] \
  || { echo "FAIL: no listed single-card slug declares 32 GB / 24 GB (got '$BIG_SLUG' / '$CTRL_SLUG')" >&2; exit 1; }

GB3090="0:RTX_3090:24576:8.6"
GB4090="0:RTX_4090:24564:8.9"
GB5090="0:RTX_5090:32607:12.0"
MIXED="0:RTX_3090:24576:8.6,1:RTX_5090:32607:12.0"

run_list() {
  # $1 = CLUB3090_FAKE_GPUS, $2 = CUDA_VISIBLE_DEVICES, rest = switch.sh args
  local fake="$1" cuda="$2"; shift 2
  CLUB3090_FAKE_GPUS="$fake" CUDA_VISIBLE_DEVICES="$cuda" NVIDIA_VISIBLE_DEVICES="" bash "$SWITCH" "$@" 2>&1
}
# The variants section only: the Defaults view below it may name any slug.
variants_of() { printf '%s\n' "$1" | sed '/^Defaults — what/,$d'; }
listed()      { [[ "$(variants_of "$1")" == *" $2 "* ]]; }

expect_listed()   { listed "$1" "$2" || note "$3: $2 should be listed"; }
expect_hidden()   { ! listed "$1" "$2" || note "$3: $2 should be hidden"; }
expect_contains() { [[ "$1" == *"$2"* ]] || note "$3: output lacks '$2'"; }
expect_lacks()    { [[ "$1" != *"$2"* ]] || note "$3: output unexpectedly has '$2'"; }

# --- 24 GB card (3090): the 32 GB slug hides, with a tally and a note --------
out="$(run_list "$GB3090" 0 --list)"
expect_hidden   "$out" "$BIG_SLUG"  "3090"
expect_listed   "$out" "$CTRL_SLUG" "3090 (24 GB control)"
expect_contains "$out" "needing cards over 24 GB hidden — --all" "3090 header tally"
expect_contains "$out" "need cards bigger than this machine's 24 GB" "3090 note"
# The rule itself, for every listed slug (covers slugs added later).
violations="$(LISTED="$(variants_of "$out")" python3 - <<'PY'
import os, pathlib, re, yaml
listed = os.environ["LISTED"]
entries = yaml.safe_load(open("scripts/lib/profiles/registry.yaml", encoding="utf-8"))["entries"]
for slug, e in sorted(entries.items()):
    p = pathlib.Path(e.get("compose_path", ""))
    if not p.is_file() or f" {slug} " not in listed:
        continue
    m = re.search(r"^#\s*Requires-min-vram-gb:\s*(\d+)", p.read_text(encoding="utf-8"), re.M)
    if m and int(m.group(1)) > 24:
        print(f"{slug} needs {m.group(1)} GB")
PY
)"
[[ -z "$violations" ]] || note "listed on a 24 GB card despite a bigger floor: ${violations//$'\n'/; }"

# --- 4090 reports 24,564 MiB: still a 24 GB card (rounding) -----------------
out="$(run_list "$GB4090" 0 --list)"
expect_listed "$out" "$CTRL_SLUG" "4090 rounding"
expect_hidden "$out" "$BIG_SLUG"  "4090"

# --- 5090 (32,607 MiB = 32 GB): both listed, no card note -------------------
out="$(run_list "$GB5090" 0 --list)"
expect_listed "$out" "$BIG_SLUG"  "5090"
expect_listed "$out" "$CTRL_SLUG" "5090"
expect_lacks  "$out" "need cards bigger" "5090 note"

# --- --all shows everything, no card tally or note --------------------------
out="$(run_list "$GB3090" 0 --list --all)"
expect_listed "$out" "$BIG_SLUG" "--all"
expect_lacks  "$out" "needing cards over" "--all tally"
expect_lacks  "$out" "need cards bigger" "--all note"

# --- the selected cards decide: 3090 + 5090 ---------------------------------
out="$(run_list "$MIXED" 1 --list)";   expect_listed "$out" "$BIG_SLUG" "selected 5090 only"
out="$(run_list "$MIXED" 0 --list)";   expect_hidden "$out" "$BIG_SLUG" "selected 3090 only"
out="$(run_list "$MIXED" 0,1 --list)"; expect_hidden "$out" "$BIG_SLUG" "both selected (smallest is 24 GB)"

# --- fail-open: a UUID selector can't be matched to a card ------------------
out="$(run_list "$GB3090" GPU-00000000-0000-0000-0000-000000000000 --list)"
expect_listed "$out" "$BIG_SLUG" "UUID selector fails open"
expect_lacks  "$out" "need cards bigger" "UUID selector note"

# --- fail-open: no readable card (no fake, no nvidia-smi on PATH) -----------
TMPBIN="$(mktemp -d)"
for b in bash sed awk sort cut tr wc env mktemp cat mv rm cp head tail printf grep python3 dirname docker curl jq; do
  src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$TMPBIN/$b"
done
out="$(PATH="$TMPBIN" CUDA_VISIBLE_DEVICES=0 NVIDIA_VISIBLE_DEVICES="" "$TMPBIN/bash" "$SWITCH" --list 2>&1)"
rm -rf "$TMPBIN"
expect_listed "$out" "$BIG_SLUG" "no readable card fails open"
expect_lacks  "$out" "need cards bigger" "no readable card note"

if [[ "$fail" -ne 0 ]]; then
  echo "[list-vram-filter] FAIL" >&2
  exit 1
fi
echo "test-list-vram-filter: ok (fixtures: $BIG_SLUG / $CTRL_SLUG)"
