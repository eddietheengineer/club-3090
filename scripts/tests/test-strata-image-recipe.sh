#!/usr/bin/env bash
# Guard: the strata-club3090 image recipe's edits to upstream's Dockerfile
# (models/qwen3.8-flash-next/strata/image/: portable.py, always; build_opts.py, opt-in).
#
# Runs against upstream's own Dockerfiles from the v0.1.44.1 and v0.1.45 releases, copied
# verbatim to fixtures/strata-image/ (Strata is MIT), once per file: v0.1.45 moved the text
# portable.py anchors on, so a recipe change has to hold for the old and the new release. The build step's Python is run
# for real against fixtures/strata-image/fake-setup.py, which builds nothing but calls run()
# the way setup.py does, so no network, docker or GPU is needed:
#   1. portable.py applies;
#   2. build_opts.py --jobs --ccache applies on top, and the build step still parses;
#   3. --jobs: every `cmake --build` gets -j N; without the edit the build keeps setup.py's own -j
#      (positive control), and a setup.py whose build command has no -j fails the build;
#   4. --ccache: the build step zeroes and reports ccache's stats, and fails when nothing went
#      through ccache (a stand-in ccache on PATH);
#   5. an anchor that isn't there exactly once refuses, as portable.py does;
#   6. build.sh refuses a bad --jobs and --ccache with --push before touching the network.
set -uo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
IMG="models/qwen3.8-flash-next/strata/image"
FIX="scripts/tests/fixtures/strata-image"

# One run per upstream Dockerfile; each run below sees one in $DF.
if [[ -z "${STRATA_TEST_DOCKERFILE:-}" ]]; then
  all=0
  for f in Dockerfile-v0.1.44.1 Dockerfile-v0.1.45; do
    echo "### $f"
    STRATA_TEST_DOCKERFILE="$f" bash "${BASH_SOURCE[0]}" || all=1
  done
  exit "$all"
fi
DF="$STRATA_TEST_DOCKERFILE"

rc=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; rc=1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A Dockerfile with portable.py applied, plus build_opts.py with the given options.
recipe() {  # <out> [build_opts args...]
  local out="$1"; shift
  cp "$FIX/$DF" "$out"
  python3 "$IMG/portable.py" "$out" || return 1
  [[ $# -eq 0 ]] || python3 "$IMG/build_opts.py" "$out" "$@"
}

# Run a Dockerfile's build step (its python heredoc) against the fake setup.py.
build_step() {  # <dockerfile> <dir>; extra env from the caller
  local df="$1" dir="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$FIX/fake-setup.py" "$dir/setup.py"
  python3 - "$df" > "$dir/step.py" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF\n", 1)[0])
PY
  (cd "$dir" && FAKE_RUN_LOG="$dir/run.log" CUDA_ARCHITECTURES=86 BUILD_VISION=1 python3 step.py)
}

# The -j of every `cmake --build` the step ran, space-separated.
build_jobs() {
  python3 - "$1/run.log" <<'PY'
import json, sys
jobs = []
for line in open(sys.argv[1], encoding="utf-8"):
    cmd = json.loads(line)
    if "--build" in cmd:
        jobs.append(cmd[cmd.index("-j") + 1] if "-j" in cmd else "none")
print(" ".join(jobs))
PY
}

echo "== 1. portable.py applies to upstream's Dockerfile"
if recipe "$work/Dockerfile.portable"; then
  command grep -q -- '"-DSTRATA_PORTABLE=ON",$' "$work/Dockerfile.portable" \
    && command grep -q '/opt/club3090/strata-cpu-flags.txt' "$work/Dockerfile.portable" \
    && ok "portable build + CPU-flag evidence" || bad "portable.py ran but its edits aren't there"
else
  bad "portable.py refused upstream's $DF"
fi

echo "== 2. build_opts.py --jobs 37 --ccache applies on top"
if recipe "$work/Dockerfile.both" --jobs 37 --ccache; then
  ok "applies"
  command grep -q 'build-essential ca-certificates ccache curl git' "$work/Dockerfile.both" \
    && ok "ccache installed in the apt layer" || bad "ccache not added to the apt layer"
  command grep -q -- "RUN --mount=type=cache,id=strata-club3090-ccache,target=/ccache .*CMAKE_CUDA_COMPILER_LAUNCHER=ccache .*\.venv/bin/python - <<'PYEOF'" "$work/Dockerfile.both" \
    && ok "build step has the cache mount and the C/C++/CUDA launchers" || bad "build step lacks the cache mount or launchers"
  python3 - "$work/Dockerfile.both" <<'PY' && ok "the build step still parses" || bad "the edited build step doesn't parse"
import sys
t = open(sys.argv[1], encoding="utf-8").read()
compile(t.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF\n", 1)[0], "build-step", "exec")
PY
else
  bad "build_opts.py refused upstream's $DF"
fi

echo "== 3. --jobs"
recipe "$work/Dockerfile.jobs" --jobs 37 || bad "build_opts.py --jobs refused"
if out="$(build_step "$work/Dockerfile.jobs" "$work/jobs" 2>&1)"; then
  got="$(build_jobs "$work/jobs")"
  [[ "$got" == "37 37" ]] && ok "both cmake --build commands ran with -j 37" || bad "build commands ran with -j: '$got' (want '37 37')"
  command grep -q '\[club3090\] cmake --build -j 37' <<<"$out" && ok "each one is printed" || bad "no '[club3090] cmake --build -j 37' line"
  [[ -f "$work/jobs/engine/BUILD.json" ]] && ok "the step finished (BUILD.json written)" || bad "no BUILD.json"
else
  bad "the build step failed: $out"
fi
# positive control: the same step without build_opts keeps setup.py's own -j
want="$(( $(nproc) / 2 < 2 ? 2 : $(nproc) / 2 ))"
if build_step "$work/Dockerfile.portable" "$work/plain" >/dev/null 2>&1; then
  got="$(build_jobs "$work/plain")"
  [[ "$got" == "$want $want" ]] && ok "without --jobs: setup.py's own -j $want" || bad "without --jobs: -j '$got' (want '$want $want')"
else
  bad "the unedited build step failed against the fake setup.py"
fi
# negative control: a setup.py whose build command has no -j
if out="$(FAKE_NO_J=1 build_step "$work/Dockerfile.jobs" "$work/noj" 2>&1)"; then
  bad "--jobs took nothing yet the build step passed"
else
  command grep -q 'no cmake --build command took -j' <<<"$out" && ok "a setup.py without -j fails the build" || bad "failed, but not with the -j message: $out"
fi

echo "== 4. --ccache"
recipe "$work/Dockerfile.ccache" --ccache || bad "build_opts.py --ccache refused"
mkdir -p "$work/bin"
cat > "$work/bin/ccache" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CCACHE_LOG"
case "$1" in
  --zero-stats) echo "Statistics zeroed" ;;
  --show-stats) echo "Hits: (stand-in)" ;;
  --print-stats) printf '%s\n' "$FAKE_CCACHE_STATS" ;;
esac
SH
chmod +x "$work/bin/ccache"
stats=$'direct_cache_hit\t4\npreprocessed_cache_hit\t1\ncache_miss\t3\nunsupported_compiler_option\t0'
if out="$(PATH="$work/bin:$PATH" FAKE_CCACHE_LOG="$work/ccache.log" FAKE_CCACHE_STATS="$stats" \
          build_step "$work/Dockerfile.ccache" "$work/cc" 2>&1)"; then
  command grep -q '\[club3090\] ccache: 5 hits, 3 misses, 0 unsupported' <<<"$out" \
    && ok "reports this build's hits and misses" || bad "no ccache summary line: $out"
  [[ "$(head -1 "$work/ccache.log")" == "--zero-stats" ]] && ok "stats zeroed before the build" || bad "ccache calls: $(tr '\n' ' ' < "$work/ccache.log")"
else
  bad "the ccache build step failed: $out"
fi
zero=$'direct_cache_hit\t0\npreprocessed_cache_hit\t0\ncache_miss\t0'
if out="$(PATH="$work/bin:$PATH" FAKE_CCACHE_LOG="$work/ccache0.log" FAKE_CCACHE_STATS="$zero" \
          build_step "$work/Dockerfile.ccache" "$work/cc0" 2>&1)"; then
  bad "nothing went through ccache yet the build step passed"
else
  command grep -q 'no compile went through ccache' <<<"$out" && ok "nothing through ccache fails the build" || bad "failed, but not with the ccache message: $out"
fi

echo "== 5. anchors must appear exactly once"
cp "$FIX/$DF" "$work/Dockerfile.dup"
python3 "$IMG/portable.py" "$work/Dockerfile.dup" >/dev/null
printf "\nRUN .venv/bin/python - <<'PYEOF'\nprint()\nPYEOF\n" >> "$work/Dockerfile.dup"
cp "$work/Dockerfile.dup" "$work/Dockerfile.dup.orig"
if err="$(python3 "$IMG/build_opts.py" "$work/Dockerfile.dup" --ccache 2>&1)"; then
  bad "build_opts.py applied to a Dockerfile with two build steps"
else
  command grep -q 'expected exactly once, found 2x' <<<"$err" && ok "two build steps refuse" || bad "refused, but not with the anchor message: $err"
  cmp -s "$work/Dockerfile.dup" "$work/Dockerfile.dup.orig" && ok "and the Dockerfile is left as it was" || bad "a refused edit changed the Dockerfile"
fi
python3 "$IMG/build_opts.py" "$work/Dockerfile.portable" >/dev/null 2>&1 \
  && bad "build_opts.py with no options exited 0" || ok "no options is an error"

echo "== 6. build.sh option checks (before any network)"
err="$(bash "$IMG/build.sh" --jobs 0 2>&1)" && bad "--jobs 0 accepted" \
  || { command grep -q -- '--jobs needs a positive number' <<<"$err" && ok "--jobs 0 refused" || bad "--jobs 0: $err"; }
err="$(bash "$IMG/build.sh" --jobs x 2>&1)" && bad "--jobs x accepted" \
  || { command grep -q -- '--jobs needs a positive number' <<<"$err" && ok "--jobs x refused" || bad "--jobs x: $err"; }
err="$(bash "$IMG/build.sh" --ccache --push 2>&1)" && bad "--ccache --push accepted" \
  || { command grep -q -- "--ccache is for builds on a rig" <<<"$err" && ok "--ccache --push refused" || bad "--ccache --push: $err"; }

if [[ "$rc" -eq 0 ]]; then echo "test-strata-image-recipe ($DF): ok"; else echo "test-strata-image-recipe ($DF): FAILED" >&2; fi
exit "$rc"
