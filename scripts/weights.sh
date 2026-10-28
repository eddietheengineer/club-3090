#!/usr/bin/env bash
# weights.sh — the weights folders a slug mounts, and removing them safely (#1814).
#
#   bash scripts/weights.sh show   <slug> [--json] [--model-dir DIR]
#   bash scripts/weights.sh remove <slug> --dry-run [--json]
#   bash scripts/weights.sh remove <slug> --yes --digest D [--allow-shared]
#
# show    every folder the slug's compose mounts (its own weights and its
#         companions: a drafter, a vision projector), with symlinks resolved, its
#         state and size, and the other slugs that use it.
# remove  deletes ONLY the recipe's `files:` in those folders, after printing
#         exactly what goes. It refuses — and deletes nothing — while another slug
#         needs a file (deprecated slugs count; --allow-shared overrides), while a
#         running container mounts the folder, for a path that leaves the model
#         directories, and for a recipe with no `files:` list. On a terminal it
#         asks after printing the plan; unattended it needs --yes AND the dry
#         run's --digest, so nothing is deleted that wasn't read first. Rules and
#         exit codes:
#         scripts/lib/weights_folders.py.
#
# MODEL_DIR comes from your settings (`bash scripts/settings.sh show`), like
# switch.sh; export it to look at another model dir.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONUTF8="${PYTHONUTF8:-1}"
# shellcheck source=lib/club-config.sh
source "${ROOT_DIR}/scripts/lib/club-config.sh"

case "${1:-}" in
  show|remove) ;;
  -h|--help|help|"")
    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    [[ -n "${1:-}" ]] && exit 0 || exit 1
    ;;
  *) echo "[weights] unknown command: $1 (show | remove)" >&2; exit 1 ;;
esac

# Only the keys this needs, not every setting: MODEL_DIR, and the file knobs a
# launch would apply to every llama.cpp compose (weights_folders counts them as
# extra users, never instead of a compose's own files).
for _k in MODEL_DIR GGUF_FILE DRAFT_FILE MMPROJ_FILE; do
  if [[ -z "${!_k+x}" ]] && _v="$(club_config_get "$_k" "$ROOT_DIR" 2>/dev/null)"; then
    export "$_k=$_v"
  fi
done
unset _k _v

exec python3 "${ROOT_DIR}/scripts/lib/weights_folders.py" --root "$ROOT_DIR" "$@"
