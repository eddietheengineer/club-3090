# image-push-guard.sh — sourced by the image recipes' build.sh (Strata, Project Maya).
#
# We publish strata-club3090 and strata-maya-club3090 from the maintainer's rig with
# `build.sh --push` (since 2026-10-17; GitHub CI built them before). CI always built a clean
# checkout of a pushed commit, so the image's recipe labels (org.opencontainers.image.revision,
# club3090.recipe) named the code that built it. A rig checkout makes no such promise: on
# 2026-10-17 a test build was labelled with its worktree's base commit while it ran an
# uncommitted portable.py. So a push requires:
#   - no uncommitted or untracked change in the recipe folder, and
#   - HEAD on origin/master (fetched now), so the labelled commit is public and holds the recipe.
#
# image_push_guard <recipe dir>: prints why and returns 1 when a push would mislabel the image.
image_push_guard() {
  local dir="$1" top dirty head
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "$dir is not in a git checkout, so the image can't name the recipe commit that built it"
    return 1
  }
  dirty="$(git -C "$top" status --porcelain --untracked-files=all -- "$dir")"
  if [[ -n "$dirty" ]]; then
    echo "the recipe folder has uncommitted changes, so the image would be labelled with a commit that doesn't hold the recipe that built it:"
    printf '%s\n' "$dirty" | sed 's/^/    /'
    echo "  Fix: commit and merge the change, then build from master."
    return 1
  fi
  git -C "$top" fetch -q origin master 2>/dev/null || {
    echo "could not fetch origin/master to check that the recipe commit is published"
    return 1
  }
  head="$(git -C "$top" rev-parse HEAD)"
  git -C "$top" merge-base --is-ancestor "$head" origin/master || {
    echo "HEAD ${head:0:8} is not on origin/master, so the image would name a commit nobody else can see."
    echo "  Fix: merge the recipe change first, then build from master (git switch master && git pull)."
    return 1
  }
}
