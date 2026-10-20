#!/usr/bin/env bash
# Guard: the image recipes refuse `build.sh --push` unless the image's recipe labels would name
# the code that built it (scripts/lib/image-push-guard.sh). Since 2026-10-17 strata-maya-club3090 is
# pushed from the maintainer's rig, not GitHub CI (as strata-club3090 was until Strata published its
# own images, 2026-10-20), and a rig build from a dirty or unpublished tree was seen labelled with the
# wrong commit.
#
# For the recipe (Project Maya), in a throwaway repo with its own bare "origin":
#   1. clean, at a commit on origin/master   → the guard passes (positive control);
#   2. a modified tracked file in the recipe → refused;
#   3. an untracked file in the recipe       → refused;
#   4. a local commit not on origin/master   → refused;
#   5. dirty but no --push                   → the guard isn't applied (test builds stay free);
#   6. a change OUTSIDE the recipe folder    → still passes (only the recipe goes into the image).
# IMAGE_PUSH_GUARD_ONLY=1 makes build.sh stop right after the guard, so nothing here touches the
# network, docker or a GPU.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A repo holding only the recipe folder and the guard library, at their real paths, with a bare
# origin that already has master. Echoes the clone's path.
fixture() {  # <name> <recipe dir>
  local name="$1" recipe="$2" src="$work/$1-src" clone="$work/$1-clone"
  mkdir -p "$src/$recipe" "$src/scripts/lib"
  cp -r "$recipe/." "$src/$recipe/"
  cp scripts/lib/image-push-guard.sh "$src/scripts/lib/"
  echo "outside" > "$src/README.md"
  git -C "$src" init -q -b master
  git -C "$src" add -A && git -C "$src" commit -q -m init
  git clone -q --bare "$src" "$work/$name-origin.git"
  git clone -q "$work/$name-origin.git" "$clone"
  echo "$clone"
}

run() {  # <clone> <recipe dir> [build.sh args...]  → prints output, returns build.sh's rc
  local clone="$1" recipe="$2"; shift 2
  IMAGE_PUSH_GUARD_ONLY=1 bash "$clone/$recipe/build.sh" "$@" 2>&1
}

for pair in "maya:models/glm-5.3-flash/strata-maya/image:Dockerfile"; do
  IFS=: read -r name recipe file <<<"$pair"
  echo "== $name ($recipe)"
  clone="$(fixture "$name" "$recipe")"

  out="$(run "$clone" "$recipe" --push)" \
    && command grep -q 'push guard passed' <<<"$out" \
    && ok "clean, on origin/master: guard passes" || bad "clean tree refused: $out"

  echo "# local edit" >> "$clone/$recipe/$file"
  if out="$(run "$clone" "$recipe" --push)"; then bad "a modified $file was pushed"
  else command grep -q 'uncommitted changes' <<<"$out" && ok "modified $file: refused" || bad "refused, but not for the edit: $out"; fi

  out="$(run "$clone" "$recipe")" \
    && command grep -q 'push guard not applied' <<<"$out" \
    && ok "same edit, no --push: guard not applied" || bad "a test build was refused: $out"
  git -C "$clone" checkout -q -- "$recipe/$file"

  touch "$clone/$recipe/stray.py"
  if out="$(run "$clone" "$recipe" --push)"; then bad "an untracked file in the recipe was pushed"
  else command grep -q 'stray.py' <<<"$out" && ok "untracked file: refused" || bad "refused, but didn't name the file: $out"; fi
  rm -f "$clone/$recipe/stray.py"

  echo "outside, edited" > "$clone/README.md"
  out="$(run "$clone" "$recipe" --push)" \
    && ok "a change outside the recipe folder doesn't block a push" || bad "an unrelated change blocked the push: $out"
  git -C "$clone" checkout -q -- README.md

  echo "# committed, not pushed" >> "$clone/$recipe/$file"
  git -C "$clone" commit -q -am "local only"
  if out="$(run "$clone" "$recipe" --push)"; then bad "a commit not on origin/master was pushed"
  else command grep -q 'not on origin/master' <<<"$out" && ok "commit not on origin/master: refused" || bad "refused, but not for the commit: $out"; fi

  git -C "$clone" push -q origin HEAD:master
  out="$(run "$clone" "$recipe" --push)" \
    && ok "the same commit, once on origin/master: guard passes" || bad "a pushed commit was refused: $out"
done

if [[ "$rc" -eq 0 ]]; then echo "test-image-push-guard: ok"; else echo "test-image-push-guard: FAILED" >&2; fi
exit "$rc"
