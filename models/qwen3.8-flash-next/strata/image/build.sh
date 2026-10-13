#!/usr/bin/env bash
# Build ghcr.io/noonghunna/strata-club3090 from one Strata release.
#
# Strata (github.com/Niko1221/Strata, MIT) publishes no Linux image and no Linux engine, only
# Windows zips and a Dockerfile, so we build that Dockerfile at the release's commit and publish
# the result (an image-provenance exception, docs/ADDING_ENGINES.md). One change goes in first:
# portable.py makes it build ggml's CPU code for an AVX2 baseline, as upstream's own ready-made
# engines are, instead of for the build machine's CPU. Strata releases about daily; CI runs this
# on a schedule (.github/workflows/strata-image.yml) and a maintainer can run it by hand:
#
#   bash models/qwen3.8-flash-next/strata/image/build.sh                    # newest release: build + check, no push
#   bash models/qwen3.8-flash-next/strata/image/build.sh --tag v0.1.43.1 --push
#   bash models/qwen3.8-flash-next/strata/image/build.sh --tag v0.1.43.1 --verify <image>   # checks only
#
# Steps; any failure stops the run:
#   1. resolve the release tag to its commit (git ls-remote, annotated tags peeled) and build
#      from that commit, so a tag moved later can't change what we built;
#   2. skip when <image>:<tag> is already published (--force rebuilds). Only "not found" means
#      unpublished: any other registry error stops the run rather than re-pushing the tag;
#   3. portable.py, then docker build with fixed build args and OCI labels (upstream commit,
#      llama.cpp pin from setup.py, archs, vision, CPU baseline, this recipe's commit);
#   4. checks on the finished image, none needing a GPU:
#      - the CPU settings both build trees were configured with (portable.py's evidence file):
#        STRATA_PORTABLE and GGML_AVX2 on, GGML_NATIVE and anything above AVX2 off;
#      - engine/BUILD.json: the release's version, our archs and vision;
#      - the first start reuses the engine instead of compiling it again: BUILD.json's source
#        hashes and the version inside the binary match the tree, as setup.py compares them;
#      - every library resolves except the host driver's (libcuda, libnvidia-*);
#      - setup.py --help still offers every flag our compose recipe passes;
#   5. with --push: push :<tag> and :sha-<commit7>, print the digest; the workflow attests it.
#
# A new image is NOT a new pin. The strata engine profile moves to one only after a rig boot
# and verify-full (engine-pin-bump.sh), so a bad release never reaches a launch.
set -euo pipefail
export PYTHONUTF8="${PYTHONUTF8:-1}"

REPO_URL="https://github.com/Niko1221/Strata"
IMAGE="${STRATA_IMAGE:-ghcr.io/noonghunna/strata-club3090}"
# Every arch upstream builds by default (RTX 20/30/40/50 + A-series): a fat binary with one cubin
# per arch, so one image serves all of them. A card outside the list (H100 is sm_90: dropped
# 2026-10-13, about a sixth of the compile for an untested arch) makes setup.py compile the engine
# for it at every fresh container's first start, because BUILD.json's archs must cover the card.
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-75;80;86;89;120}"
BUILD_VISION="${BUILD_VISION:-1}"
# The setup.py flags our composes pass (models/qwen3.8-flash-next/strata/launcher/strata-entrypoint.sh).
# A release that drops or renames one would break every launch, so the build fails instead.
REQUIRED_SETUP_FLAGS="${REQUIRED_SETUP_FLAGS:---setup --yes --family --model --gguf-dir --context --vision --data-dir --host --api-key --port --gpus --gpu --no-start --kv}"

TAG="" PUSH=0 FORCE=0 VERIFY=""
usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --force) FORCE=1; shift ;;
    --verify) VERIFY="${2:?--verify needs an image}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[strata-image] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { echo "[strata-image] $*"; }
die() { echo "[strata-image] ERROR: $*" >&2; exit 1; }
out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
recipe_commit="$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"

# ── checks on a built image (step 4) ────────────────────────────────────────────────
check_image() {
  local ref="$1" version="$2" evidence build_json reuse missing help absent f bins
  local run=(docker run --rm --entrypoint)

  evidence="$("${run[@]}" cat "$ref" /opt/club3090/strata-cpu-flags.txt 2>/dev/null)" \
    || die "$ref has no /opt/club3090/strata-cpu-flags.txt: not built through portable.py, so its CPU code may be native to the build machine"
  python3 - "$evidence" "$BUILD_VISION" <<'PY' || die "the engine is not a portable (AVX2-baseline) build"
import sys
evidence, vision = sys.argv[1], sys.argv[2]
seen = {}
for line in evidence.splitlines():
    tree, _, setting = line.partition(" ")
    name, _, value = setting.partition("=")
    seen.setdefault(tree, {})[name.split(":")[0]] = value.strip().upper()
bad = []
for tree in ["build"] + (["build-vision"] if vision == "1" else []):
    s = seen.get(tree)
    if not s:
        bad.append(f"{tree}: no CPU settings recorded")
        continue
    for name, want in (("STRATA_PORTABLE", "ON"), ("GGML_NATIVE", "OFF"), ("GGML_AVX2", "ON")):
        if s.get(name) != want:
            bad.append(f"{tree}: {name}={s.get(name, '(unset)')}, want {want}")
    for name, value in sorted(s.items()):
        if name.startswith(("GGML_AVX512", "GGML_AVX_VNNI", "GGML_AMX_")) and value != "OFF":
            bad.append(f"{tree}: {name}={value}, want OFF (above the AVX2 baseline)")
for m in bad:
    print(f"[strata-image]   {m}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  say "check: both build trees configured portable (STRATA_PORTABLE on, GGML_NATIVE off, nothing above AVX2)"

  build_json="$("${run[@]}" cat "$ref" /opt/strata/engine/BUILD.json)" || die "engine/BUILD.json missing: the engine was not built"
  python3 - "$build_json" "$version" "$CUDA_ARCHITECTURES" "$BUILD_VISION" <<'PY' || die "engine/BUILD.json does not match this build"
import json, sys
b = json.loads(sys.argv[1]); version, archs, vision = sys.argv[2], sys.argv[3], sys.argv[4]
want_archs = sorted(int(a.split("-")[0]) for a in archs.replace(",", ";").split(";") if a.strip())
want_vision = "gpu" if vision == "1" else "none"
bad = []
if b.get("source") != "local": bad.append(f"source {b.get('source')!r} != 'local'")
if b.get("version") != version: bad.append(f"version {b.get('version')!r} != {version!r}")
if sorted(b.get("archs", [])) != want_archs: bad.append(f"archs {b.get('archs')} != {want_archs}")
if b.get("vision") != want_vision: bad.append(f"vision {b.get('vision')!r} != {want_vision!r}")
for m in bad: print(f"[strata-image]   {m}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  say "check: BUILD.json says $version, archs $CUDA_ARCHITECTURES, vision $BUILD_VISION"

  # setup.py's own reuse test (build_engine), less the parts that depend on the host's cards and CPU
  reuse="$(docker run --rm -w /opt/strata --entrypoint /opt/strata/.venv/bin/python "$ref" -c '
import json, setup
m = json.load(open("engine/BUILD.json"))
exe = setup.ROOT / "engine" / setup.EXE
bad = []
if m.get("src") != setup.source_hash(setup.ENGINE_SOURCES): bad.append("engine source hash differs from the tree")
if m.get("vision") != "none" and m.get("vision_src") != setup.source_hash(setup.VISION_SOURCES):
    bad.append("vision source hash differs from the tree")
if setup.stale_binary(exe):
    bad.append(f"engine binary is {setup.binary_engine_version(exe)}, the tree {setup.source_version()}")
print("; ".join(bad) or "ok")
' 2>&1)" || die "could not run setup.py's reuse test: $reuse"
  [[ "$(tail -1 <<<"$reuse")" == ok ]] || die "the first start would compile the engine again: $reuse"
  say "check: the first start reuses the built engine (source hashes and binary version match)"

  bins="/opt/strata/engine/strata"
  [[ "$BUILD_VISION" == 1 ]] && bins="$bins /opt/strata/engine/strata-vision"
  # libcuda / libnvidia-* come from the host driver at run time, so only those may be missing here
  missing="$("${run[@]}" sh "$ref" -c "for b in $bins; do ldd \"\$b\"; done" | command grep 'not found' \
             | command grep -v -E 'libcuda\.so|libnvidia' || true)"
  [[ -z "$missing" ]] || die "libraries missing from the image:
$missing"
  say "check: every library resolves except the host driver's"

  help="$(docker run --rm -w /opt/strata --entrypoint /opt/strata/.venv/bin/python "$ref" setup.py --help 2>&1)" \
    || die "setup.py --help failed:
$help"
  absent=""
  for f in $REQUIRED_SETUP_FLAGS; do
    command grep -q -E -- "(^|[^a-z-])$f([^a-z-]|$)" <<<"$help" || absent="$absent $f"
  done
  [[ -z "$absent" ]] || die "setup.py no longer offers:$absent (our composes pass them; update launcher/strata-entrypoint.sh before taking this release)"
  say "check: setup.py offers every flag our recipe passes"
}

# ── 1. the release and its commit ────────────────────────────────────────────────
if [[ -z "$TAG" ]]; then
  [[ -z "$VERIFY" ]] || die "--verify needs --tag (the release the image should be)"
  # newest tag by version order: releases are tagged vMAJOR.MINOR.PATCH[.N]
  TAG="$(git ls-remote --tags --refs "$REPO_URL" 'v*' | awk '{sub("refs/tags/","",$2); print $2}' \
         | command grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
  [[ -n "$TAG" ]] || die "no release tags found at $REPO_URL"
fi
[[ "$TAG" =~ ^v[0-9]+(\.[0-9]+)+$ ]] || die "'$TAG' doesn't look like a Strata release tag (vX.Y.Z[.N])"
version="${TAG#v}"

if [[ -n "$VERIFY" ]]; then
  check_image "$VERIFY" "$version"
  say "$VERIFY passes every check for $TAG"
  exit 0
fi

refs="$(git ls-remote "$REPO_URL" "refs/tags/$TAG" "refs/tags/$TAG^{}")"
commit="$(awk -v t="refs/tags/$TAG^{}" '$2 == t {print $1}' <<<"$refs")"
[[ -n "$commit" ]] || commit="$(awk -v t="refs/tags/$TAG" '$2 == t {print $1}' <<<"$refs")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "tag $TAG not found at $REPO_URL"
short="${commit:0:7}"
say "release $TAG = commit $commit"
out "tag=$TAG"; out "commit=$commit"

# ── 2. already published? ─────────────────────────────────────────────────────────
if [[ "$FORCE" != 1 ]]; then
  if probe="$(docker buildx imagetools inspect "$IMAGE:$TAG" 2>&1)"; then
    say "$IMAGE:$TAG is already published; nothing to do (--force rebuilds)"
    out "skipped=true"
    exit 0
  fi
  command grep -q -i 'not found' <<<"$probe" \
    || die "could not tell whether $IMAGE:$TAG is published (not rebuilding over it):
$probe"
fi

# ── 3. build ────────────────────────────────────────────────────────────────────────
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -C "$work" init -q
git -C "$work" remote add origin "$REPO_URL"
git -C "$work" fetch -q --depth 1 origin "$commit"
git -C "$work" checkout -q FETCH_HEAD
[[ "$(git -C "$work" rev-parse HEAD)" == "$commit" ]] || die "checked-out commit is not $commit"
[[ -f "$work/Dockerfile" ]] || die "the release has no Dockerfile"
llama="$(command grep -m1 -E '^LLAMA_CPP_COMMIT *= *"[0-9a-f]{40}"' "$work/setup.py" | command grep -o -E '[0-9a-f]{40}' || true)"
[[ -n "$llama" ]] || die "setup.py has no LLAMA_CPP_COMMIT: upstream changed how it pins llama.cpp"
python3 "$here/portable.py" "$work/Dockerfile" || die "portable.py could not apply to $TAG's Dockerfile"

say "building $IMAGE:$TAG (archs $CUDA_ARCHITECTURES, vision $BUILD_VISION, AVX2 baseline, llama.cpp ${llama:0:7})"
docker build --pull \
  --build-arg "CUDA_ARCHITECTURES=$CUDA_ARCHITECTURES" \
  --build-arg "BUILD_VISION=$BUILD_VISION" \
  --label "org.opencontainers.image.title=strata-club3090" \
  --label "org.opencontainers.image.description=Strata $TAG built by club-3090 from upstream's Dockerfile at the release commit, with ggml's CPU code for an AVX2 baseline (portable.py)" \
  --label "org.opencontainers.image.source=https://github.com/noonghunna/club-3090" \
  --label "org.opencontainers.image.revision=$recipe_commit" \
  --label "org.opencontainers.image.version=$TAG" \
  --label "org.opencontainers.image.licenses=MIT" \
  --label "club3090.upstream.source=$REPO_URL" \
  --label "club3090.upstream.revision=$commit" \
  --label "club3090.recipe=https://github.com/noonghunna/club-3090/tree/$recipe_commit/models/qwen3.8-flash-next/strata/image" \
  --label "club3090.cuda_architectures=$CUDA_ARCHITECTURES" \
  --label "club3090.build_vision=$BUILD_VISION" \
  --label "club3090.cpu_baseline=avx2-portable" \
  --label "club3090.llama_cpp_commit=$llama" \
  -t "$IMAGE:$TAG" -t "$IMAGE:sha-$short" "$work"

# ── 4. checks ──────────────────────────────────────────────────────────────────────
check_image "$IMAGE:$TAG" "$version"

# ── 5. publish ──────────────────────────────────────────────────────────────────────
if [[ "$PUSH" != 1 ]]; then
  say "built and checked $IMAGE:$TAG (not pushed; --push publishes)"
  exit 0
fi
docker push -q "$IMAGE:$TAG" >/dev/null
docker push -q "$IMAGE:sha-$short" >/dev/null
digest="$(docker buildx imagetools inspect "$IMAGE:$TAG" --format '{{json .Manifest.Digest}}' | tr -d '"')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not read the pushed digest (got '$digest')"
say "pushed $IMAGE:$TAG and :sha-$short = $IMAGE@$digest"
out "digest=$digest"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### strata-club3090 $TAG"
    echo
    echo "- Upstream commit \`$commit\` · llama.cpp \`${llama:0:7}\` · archs \`$CUDA_ARCHITECTURES\` · vision \`$BUILD_VISION\` · CPU baseline AVX2 (portable)"
    echo "- Image \`$IMAGE@$digest\` (also \`:$TAG\`, \`:sha-$short\`)"
    echo "- All image checks passed. **Not pinned:** the strata engine profile moves to it only after a rig boot + verify-full (\`engine-pin-bump.sh\`)."
  } >> "$GITHUB_STEP_SUMMARY"
fi
