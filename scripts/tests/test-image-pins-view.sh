#!/usr/bin/env bash
# Guard for where an engine pin lives: in the engine's profile, not in docs/UPSTREAM.md.
#
# docs/UPSTREAM.md's Pinned images table says why each image is pinned, which composes use it and when
# the pin can retire. The pin itself is in the profile: install.spec, plus the `# pin-current:` and
# `# pin-earlier:` lines beside it. So a bump edits the files of one engine, and bumps of two engines
# never conflict in the shared table (four of six PR pairs did on 2026-10-27, all on that table). What
# it holds:
#   - every non-deprecated engine with a Pinned images row has a `# pin-current:` line in its profile;
#   - no such row repeats the engine's current pin (its digest, or its spec when tag-pinned), or lists
#     earlier pins;
#   - `list-image-pins.sh --pins` prints each engine's image and pin-current line, `--history` adds the
#     earlier pins one per line, `--filter` narrows it, and pip installs (no image) are left out;
#   - negative controls: the row check fails on a copy of UPSTREAM.md with a digest put back and with a
#     tag put back, and the pin-current check fails on a profile without the line.
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "ASSERTION FAILED: $1" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }

UP="$ROOT_DIR/docs/UPSTREAM.md"
ENG="$ROOT_DIR/scripts/lib/profiles/engines"
VIEW="$ROOT_DIR/scripts/maintenance/list-image-pins.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

row_ids() { command grep -oE '^\| `scripts/lib/profiles/engines/[a-z0-9.-]+\.yml` →' "$1" | sed -E 's#.*engines/([a-z0-9.-]+)\.yml.*#\1#'; }
spec_of() { command grep -m1 -E '^[[:space:]]+spec:[[:space:]]+' "$1" | sed -E 's/^[[:space:]]+spec:[[:space:]]+//; s/[[:space:]]+#.*$//' | tr -d '"'; }
# what identifies the pin in prose: the digest's first 8 hex, or the whole spec of a tag pin
pin_key() { if [[ "$1" == *@sha256:* ]]; then printf 'sha256:%s' "$(printf '%s' "${1#*@sha256:}" | cut -c1-8)"; else printf '%s' "$1"; fi; }
pin_current() { command grep -m1 -E '^[[:space:]]+# pin-current:' "$1" | sed -E 's/^[[:space:]]+# pin-current:[[:space:]]*//'; }

# check <upstream.md> <engines dir>: one line per violation, and the checked ids in $TMP/checked
check() {
  local up="$1" eng="$2" id y row spec
  : > "$TMP/checked"
  for id in $(row_ids "$up"); do
    y="$eng/$id.yml"
    [[ -f "$y" ]] || { echo "$id: its row names a profile that doesn't exist"; continue; }
    command grep -qE '^stability:[[:space:]]+deprecated' "$y" && continue
    echo "$id" >> "$TMP/checked"
    command grep -qE '^[[:space:]]+# pin-current:' "$y" || echo "$id: no # pin-current: line in its profile"
    spec="$(spec_of "$y")"
    [[ -n "$spec" ]] || { echo "$id: no install.spec in its profile"; continue; }
    row="$(command grep -F "| \`scripts/lib/profiles/engines/$id.yml\` →" "$up")"
    [[ "$row" != *"$(pin_key "$spec")"* ]] || echo "$id: its Pinned images row repeats the current pin ($(pin_key "$spec"))"
    [[ "$row" != *"Earlier pins:"* ]] || echo "$id: its Pinned images row lists earlier pins (they belong in pin-earlier)"
  done
}

# ── 1. the real tree holds ──────────────────────────────────────────────────────────────────────────
v="$(check "$UP" "$ENG")"
[[ -z "$v" ]] || fail "the pin lives in the profile, not docs/UPSTREAM.md:\n$v"
for id in strata strata-maya vllm-stable llama-cpp-local; do
  command grep -qx "$id" "$TMP/checked" || fail "$id's row was not checked (row_ids or the stability skip is wrong)"
done
ok

# ── 2. negative controls: each kind of violation is caught ──────────────────────────────────────────
key="$(pin_key "$(spec_of "$ENG/strata.yml")")"
sed "s#^\(| \`scripts/lib/profiles/engines/strata.yml\` → \)#\1$key #" "$UP" > "$TMP/up-digest.md"
command grep -qx "strata: its Pinned images row repeats the current pin ($key)" <<<"$(check "$TMP/up-digest.md" "$ENG")" \
  || fail "a digest put back into strata's row was not caught"
ok
tag="$(spec_of "$ENG/vllm-stable.yml")"
[[ "$tag" != *@sha256:* ]] || fail "vllm-stable is expected to be tag-pinned (the tag branch of this test)"
sed "s#^\(| \`scripts/lib/profiles/engines/vllm-stable.yml\` → \)#\1\`$tag\` #" "$UP" > "$TMP/up-tag.md"
command grep -qx "vllm-stable: its Pinned images row repeats the current pin ($tag)" <<<"$(check "$TMP/up-tag.md" "$ENG")" \
  || fail "a tag put back into vllm-stable's row was not caught"
ok
cp -r "$ENG" "$TMP/engines"
sed -i '/^[[:space:]]*# pin-current:/d' "$TMP/engines/strata-maya.yml"
command grep -qx "strata-maya: no # pin-current: line in its profile" <<<"$(check "$UP" "$TMP/engines")" \
  || fail "a profile without pin-current was not caught"
ok

# ── 3. the view prints what the profiles say ────────────────────────────────────────────────────────
out="$(bash "$VIEW" --pins)"
[[ "$(head -1 <<<"$out")" == "| Engine | Image (\`install.spec\`) | Current pin (\`# pin-current:\`) | Rollback (first \`# pin-earlier:\`) |" ]] \
  || fail "--pins header wrong: $(head -1 <<<"$out")"
while read -r id; do
  y="$ENG/$id.yml"; spec="$(spec_of "$y")"; cur="$(pin_current "$y")"
  line="$(command grep -F "| \`$id\` |" <<<"$out")" || fail "--pins has no row for $id"
  [[ "$line" == *"$cur"* ]] || fail "--pins row for $id lacks its pin-current line: $line"
  if [[ "$spec" == *@sha256:* ]]; then
    [[ "$line" == *"@sha256:$(printf '%s' "${spec#*@sha256:}" | cut -c1-12)…"* ]] || fail "--pins row for $id lacks its digest: $line"
  else
    [[ "$line" == *"\`$spec\`"* ]] || fail "--pins row for $id lacks its spec: $line"
  fi
done < "$TMP/checked"
ok
first="$(command grep -m1 -E '^[[:space:]]+# pin-earlier:' "$ENG/strata-maya.yml" | sed -E 's/^[[:space:]]+# pin-earlier:[[:space:]]*//')"
first="${first%%); *})"   # the first entry ends at the first `); ` (a `;` inside its parentheses doesn't end it)
[[ "$(command grep -F '| `strata-maya` |' <<<"$out")" == *"| $first |" ]] || fail "--pins rollback for strata-maya is not its first pin-earlier entry ($first)"
ok
for id in $(command grep -lE '^[[:space:]]+method:[[:space:]]+pip' "$ENG"/*.yml | xargs -r -n1 basename | sed 's/\.yml$//'); do
  ! command grep -qF "| \`$id\` |" <<<"$out" || fail "--pins lists $id, a pip install with no image"
done
ok
hist="$(bash "$VIEW" --pins --history --filter strata-maya)"
[[ "$(command grep -c '^| `' <<<"$hist")" == 1 ]] || fail "--filter strata-maya should leave one engine row: $hist"
command grep -qxF "  - $first" <<<"$hist" || fail "--history should list strata-maya's first earlier pin on its own line: $hist"
[[ "$(command grep -c '^  - ' <<<"$hist")" -ge 2 ]] || fail "--history should split every earlier pin, ';' inside parentheses included: $hist"
ok

echo "test-image-pins-view: ok ($pass checks)"
