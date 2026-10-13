#!/bin/sh
# Strata entrypoint for the qwen3.8-flash-next composes; both topologies mount this file.
# It replaces the image's docker-entrypoint.sh, which cannot pass --gguf-dir: the weights
# come from our model directory, mounted read-only at /gguf, not from Strata's own download.
#
#   SETUP_ONLY=1         run the one-time setup (SHA-256 check, pack, MTP layer) and exit,
#                        so the boot that gets benched is not the one that did the setup
#   REINSTALL=1          redo the setup for an existing config
#   STRATA_START_GPUS    the cards to start on, as the container sees them: "0,1" (the dual
#                        compose's default, a layer split) or one number (single card)
#
# Everything Strata writes (packs, the MTP layer, the config) goes to /data.
set -eu
umask 0002                   # group-writable, so the launcher's user can clear /data
cd /opt/strata

DATA=/data
SRC=/gguf                    # our IQ3_S folder, mounted READ-ONLY
LINKS="$DATA/gguf-links-iq3s"
FAMILY=qwen
MODEL=IQ3_S
tag="iq3_s"                  # setup.py: fam["tag"] ("" for the original) + model, lower-cased
cfg="$DATA/config/strata-$tag.json"
mkdir -p "$DATA/config" "$LINKS"

# ⚠️ setup.py SHA-256-checks the shards and DELETES one that mismatches: point it at
# SYMLINKS on the data volume so the read-only model tree is never written.
for f in "$SRC"/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-0000?-of-00002.gguf; do
  ln -sfn "$f" "$LINKS/$(basename "$f")"
done

if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  case "${STRATA_START_GPUS:-0,1}" in *,*) gsel="--gpus" ;; *) gsel="--gpu" ;; esac
  set -- --family "$FAMILY" --model "$MODEL" --gguf-dir "$LINKS" \
    --context "${CONTEXT:-131072}" --vision no --data-dir "$DATA" \
    --host "${HOST:-0.0.0.0}" --api-key "${API_KEY:-}" --port "${PORT:-8080}" \
    "$gsel" "${STRATA_START_GPUS:-0,1}" --no-start
  if [ -n "${KV:-}" ]; then set -- "$@" --kv "$KV"; fi
  .venv/bin/python setup.py --setup --yes "$@"
  cp -f "/opt/strata/strata-$tag.json" "$cfg"
else
  [ -e "/opt/strata/strata-$tag.json" ] || ln -s "$cfg" "/opt/strata/strata-$tag.json"
fi

if [ "${SETUP_ONLY:-0}" = "1" ]; then
  echo "[strata-recipe] setup done, config: $cfg"
  exit 0
fi
# No --model here: setup.py treats it as a setup request. A fresh container links only this
# config into /opt/strata, so the plain start picks it (installed_configs() == 1).
case "${STRATA_START_GPUS:-0,1}" in
  *,*) exec .venv/bin/python setup.py --port "${PORT:-8080}" --gpus "$STRATA_START_GPUS" ;;
  *)   exec .venv/bin/python setup.py --port "${PORT:-8080}" --gpu "$STRATA_START_GPUS" ;;
esac
