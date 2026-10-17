#!/usr/bin/env bash
# Gate: setup.sh's weight download must survive ONE transient network stall
# (club-3090#1305).
#
# THE DEFECT
# ----------
# `_hf_download_repo` called `hf download` exactly once. Under `set -euo
# pipefail` a single mid-transfer stall — reproduced in the wild as
# `httpx.ConnectTimeout: _ssl.c:1015: The handshake operation timed out`
# against a hub that was otherwise answering in 0.65s — aborted the whole setup
# run with a ~40-line unhandled Python traceback, 1.1 GB into a 17 GB download.
#
# The recovery was trivial and entirely undiscoverable: re-running the identical
# command resumed from the `.incomplete` markers the hub client had already
# written. Nothing in the output said so, so a first-time user reads the
# traceback as "this is broken" rather than "run it again".
#
# ASSERTED HERE (hermetic — no network, no weights, no GPU)
# ---------------------------------------------------------
#   1. a clean download still takes exactly one attempt (no gratuitous retries);
#   2. two transient failures followed by success => the download SUCCEEDS, and
#      the retry is announced rather than silent;
#   3. a permanent failure is BOUNDED (it does not retry forever) and exits
#      non-zero;
#   4. that final failure message says the transfer is resumable and that
#      re-running the same command continues it — the sentence whose absence
#      was the actual user-visible bug.
#
# The function is mid-script in a setup.sh that would otherwise run a whole
# installer, so extract it and drive it directly (the shape
# test-setup-verify-count.sh uses for _verify_downloaded_files).
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SETUP="$ROOT_DIR/scripts/setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

awk '/^_hf_download_repo\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SETUP" > "$TMP/fn.sh"
command grep -q '_hf_download_repo()' "$TMP/fn.sh" \
  || fail "could not extract _hf_download_repo from setup.sh (did its shape change?)"
command grep -q '^}$' "$TMP/fn.sh" || fail "extraction did not capture the function's closing brace"

mkdir -p "$TMP/bin"
# Fake hf CLI: fails the first $(cat failuntil) attempts the way the real one
# does — non-zero exit with a traceback tail on stderr — then succeeds.
cat > "$TMP/bin/hf" <<SH
#!/usr/bin/env bash
n=\$(cat "$TMP/attempts" 2>/dev/null || echo 0)
n=\$((n + 1)); printf '%s' "\$n" > "$TMP/attempts"
if [ "\$n" -le "\$(cat "$TMP/failuntil")" ]; then
  echo "Traceback (most recent call last):" >&2
  echo "httpx.ConnectTimeout: _ssl.c:1015: The handshake operation timed out" >&2
  exit 1
fi
exit 0
SH
chmod +x "$TMP/bin/hf"

# run_case <fail-this-many-attempts> — sets OUT, RC and ATTEMPTS as globals.
# NOT called in $( ): command substitution runs it in a subshell, and the rc it
# captured would never reach the caller (it reads as "unbound variable", which is
# at least loud — a defaulted one would have silently scored every case as pass).
run_case() {
  printf '%s' "$1" > "$TMP/failuntil"
  printf '0' > "$TMP/attempts"
  set +e
  OUT="$(PATH="$TMP/bin:$PATH" \
    MODEL_DIR="$TMP/models" \
    HF_DOWNLOAD_RETRY_SLEEP=0 \
    bash -c '
      set -uo pipefail
      source "'"$TMP"'/fn.sh"
      ensure_hf_cli() { return 0; }
      _hf_download_repo some/repo subdir
    ' 2>&1)"
  RC=$?
  set -e
  ATTEMPTS="$(cat "$TMP/attempts")"
}

# --- 1. clean download: exactly one attempt --------------------------------
run_case 0; out="$OUT"
[[ "$RC" -eq 0 ]] || fail "case 1: a clean download failed (rc=$RC): $out"
[[ "$ATTEMPTS" == "1" ]] || fail "case 1: clean download took $ATTEMPTS attempts, expected 1"
echo "  ✓ a clean download still takes exactly one attempt"

# --- 2. two transient stalls, then success ---------------------------------
run_case 2; out="$OUT"
[[ "$RC" -eq 0 ]] || fail "case 2: two transient stalls were not survived (rc=$RC): $out"
[[ "$ATTEMPTS" == "3" ]] || fail "case 2: expected 3 attempts (2 stalls + 1 success), got $ATTEMPTS"
command grep -qi 'retry' <<<"$out" || fail "case 2: the retry was silent — nothing in the output says it retried: $out"
echo "  ✓ two transient stalls are retried and the download completes"

# --- 3. permanent failure is bounded and non-zero --------------------------
run_case 999; out="$OUT"
[[ "$RC" -ne 0 ]] || fail "case 3: a permanently failing download reported success"
(( ATTEMPTS >= 2 )) || fail "case 3: a permanent failure was never retried at all ($ATTEMPTS attempt)"
(( ATTEMPTS <= 8 )) || fail "case 3: unbounded retry — $ATTEMPTS attempts"
echo "  ✓ a permanent failure retries a bounded number of times ($ATTEMPTS) and exits non-zero"

# --- 4. the give-up message tells the user what to do ----------------------
command grep -qi 'resum' <<<"$out" \
  || fail "case 4: the give-up message never says the transfer is resumable: $out"
command grep -qiE 're-?run|run (it|the same)' <<<"$out" \
  || fail "case 4: the give-up message never says re-running continues the download: $out"
echo "  ✓ the give-up message says the transfer is resumable and re-running continues it"

# --- 5. a mistyped knob errors clearly, it does not crash ------------------
# `(( attempt >= max ))` resolves a non-numeric `max` as a VARIABLE name, so
# under `set -u` the pre-fix shape died with "foo: unbound variable" — a crash
# inside the code that exists to handle crashes.
printf '1' > "$TMP/failuntil"; printf '0' > "$TMP/attempts"
set +e
bad="$(PATH="$TMP/bin:$PATH" MODEL_DIR="$TMP/models" HF_DOWNLOAD_RETRIES=foo \
  bash -c '
    set -uo pipefail
    source "'"$TMP"'/fn.sh"
    ensure_hf_cli() { return 0; }
    _hf_download_repo some/repo subdir
  ' 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] || fail "case 5: a non-numeric HF_DOWNLOAD_RETRIES was accepted"
command grep -q 'unbound variable' <<<"$bad" \
  && fail "case 5: a mistyped knob crashes on an unbound variable instead of erroring: $bad"
command grep -q 'HF_DOWNLOAD_RETRIES' <<<"$bad" \
  || fail "case 5: the error does not name the offending variable: $bad"
echo "  ✓ a mistyped retry knob gets a clear error, not an unbound-variable crash"

# --- 6-8. a file over the 50 GB classic ceiling goes through the ladder (paulp83, #1700) ---
# A fake hf_fetch.py under a fake ROOT_DIR: `--preflight` prints the verdict in $TMP/verdict;
# a real run records its argv and exits with $TMP/ladder_rc.
mkdir -p "$TMP/root/scripts/lib/profiles"
cat > "$TMP/root/scripts/lib/profiles/hf_fetch.py" <<FAKE
import sys
args = sys.argv[1:]
if "--preflight" in args:
    print("transport: " + open("$TMP/verdict").read().strip()); sys.exit(0)
open("$TMP/ladder_argv", "w").write(" ".join(args))
sys.exit(int(open("$TMP/ladder_rc").read()))
FAKE
ladder_case() {  # <verdict> <ladder rc>
  printf '%s' "$1" > "$TMP/verdict"; printf '%s' "$2" > "$TMP/ladder_rc"
  printf '0' > "$TMP/failuntil"; printf '0' > "$TMP/attempts"; rm -f "$TMP/ladder_argv"
  set +e
  OUT="$(PATH="$TMP/bin:$PATH" MODEL_DIR="$TMP/models" ROOT_DIR="$TMP/root" HF_DOWNLOAD_RETRY_SLEEP=0 \
    bash -c '
      set -uo pipefail
      source "'"$TMP"'/fn.sh"
      ensure_hf_cli() { return 0; }
      _hf_download_repo big/repo subdir "IQ3_S/big-00001-of-00002.gguf IQ3_S/big-00002-of-00002.gguf" abc123
    ' 2>&1)"
  RC=$?
  set -e
  ATTEMPTS="$(cat "$TMP/attempts")"
}
ladder_case needs-fallback 0
[[ "$RC" -eq 0 && "$ATTEMPTS" == "0" ]] || fail "case 6: needs-fallback did not go to the ladder (rc=$RC, hf attempts=$ATTEMPTS): $OUT"
argv="$(cat "$TMP/ladder_argv" 2>/dev/null)"
[[ "$argv" == *"big/repo"*"--revision abc123"*"--include IQ3_S/big-00001-of-00002.gguf"*"--include IQ3_S/big-00002-of-00002.gguf"* ]] \
  || fail "case 6: the ladder got the wrong arguments: '$argv'"
command grep -q '50 GB' <<<"$OUT" || fail "case 6: the switch to the ladder is silent: $OUT"
echo "  ✓ a file over 50 GB goes through the ladder (repo, revision, every file), with no doomed hf attempt"
ladder_case needs-fallback 1
[[ "$RC" -ne 0 && "$ATTEMPTS" == "0" ]] || fail "case 7: a failed ladder returned rc=$RC or retried hf ($ATTEMPTS): $OUT"
command grep -qi 're-run' <<<"$OUT" || fail "case 7: the ladder failure says nothing about re-running: $OUT"
echo "  ✓ a failed ladder exits non-zero and says to re-run (no retries of the refused classic path)"
ladder_case classic 0
[[ "$RC" -eq 0 && "$ATTEMPTS" == "1" && ! -f "$TMP/ladder_argv" ]] || fail "case 8: a classic pull did not take the normal path (rc=$RC, attempts=$ATTEMPTS)"
echo "  ✓ a pull the classic path can serve takes the normal path (one hf attempt, no ladder)"

# --- 9. the recommended-defaults mode reports a failed model instead of "✓ All downloaded" ---
awk '/^if \[\[ "\$\{SETUP_BOTH_MODE:-0\}" == "1" \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$SETUP" > "$TMP/both.sh"
command grep -q 'All recommended models downloaded' "$TMP/both.sh" || fail "case 9: could not extract the SETUP_BOTH_MODE block from setup.sh"
cat > "$TMP/child.sh" <<'CHILD'
[ "$1" = bad-model ] && exit 1
exit 0
CHILD
both_case() {  # <models...> -> OUT, RC
  set +e
  OUT="$(SETUP_BOTH_MODE=1 MODEL_DIR="$TMP/models" bash -c 'BOTH_MODELS=("$@"); source "'"$TMP"'/both.sh"' "$TMP/child.sh" "$@" 2>&1)"
  RC=$?
  set -e
}
both_case good-model bad-model
[[ "$RC" -ne 0 ]] || fail "case 9: a failed model still exited 0: $OUT"
command grep -q 'bad-model' <<<"$OUT" && ! command grep -q 'All recommended models downloaded' <<<"$OUT" \
  || fail "case 9: the failure isn't named, or it still says all were downloaded: $OUT"
both_case good-model good-model
[[ "$RC" -eq 0 ]] && command grep -q 'All recommended models downloaded' <<<"$OUT" \
  || fail "case 9: an all-good run did not report success (rc=$RC): $OUT"
echo "  ✓ the recommended-defaults mode names a failed model and exits non-zero (and still succeeds when all succeed)"

echo "test-setup-download-retry: ok (club-3090#1305)"
