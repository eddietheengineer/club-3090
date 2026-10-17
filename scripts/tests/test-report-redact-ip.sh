#!/usr/bin/env bash
# Gate: report.sh's redacted bundle masks LAN / private IPv4 addresses (paulp83, #1700: the
# Settings section printed the saved LANIP, and nothing masked an address).
#   1. this machine's own addresses (REDACT_IPS: the saved LANIP + `hostname -I`) are masked
#      whatever range they are in, a public one included;
#   2. any 10/8, 172.16/12, 192.168/16 or 100.64/10 address is masked, adjacent ones too;
#   3. loopback, 0.0.0.0, a public address that isn't this machine's, and dotted version
#      strings (0.1.44.1, 1.25.1, b10.0.0.1x) are left alone;
#   4. --no-redact (REDACT=0) masks nothing.
# Drives report.sh's own strip_ansi / redact_ips / redact, extracted (no docker, no GPU).
set -euo pipefail
export CLUB3090_CONFIG_DIR=/nonexistent/club-3090-test-config   # tests never read your real settings (#1466)
export PYTHONUTF8="${PYTHONUTF8:-1}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
for fn in strip_ansi redact_ips redact; do
  awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' scripts/report.sh >> "$TMP/fns.sh"
done
for fn in strip_ansi redact_ips redact; do command grep -q "^$fn() {" "$TMP/fns.sh" || { echo "FAIL: could not extract $fn" >&2; exit 1; }; done
fails=0
check() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; else echo "  ✗ $1: got '$2', want '$3'" >&2; fails=$((fails+1)); fi; }
run() { ( source "$TMP/fns.sh"; REDACT="$1" REDACT_IPS="$2" USER_NAME=nobody-x HOST_SHORT=nohost-x MODEL_DIR=; printf '%s\n' "$3" | redact ); }
OWN="203.0.113.9 192.168.1.50"
check "the saved LANIP in the Settings table" "$(run 1 "$OWN" 'LANIP=192.168.1.50 (club3090.env)')" 'LANIP=<LAN_IP> (club3090.env)'
check "this machine's public address"       "$(run 1 "$OWN" 'bound on 203.0.113.9:8080')" 'bound on <LAN_IP>:8080'
check "a 10/8 URL"                          "$(run 1 "" 'http://10.0.0.7:8080/v1')" 'http://<LAN_IP>:8080/v1'
check "172.16/12 and 100.64/10"             "$(run 1 "" 'peer 172.20.1.4 via 100.101.102.103')" 'peer <LAN_IP> via <LAN_IP>'
check "adjacent addresses"                  "$(run 1 "" '10.0.0.1,10.0.0.2 192.168.0.1/192.168.0.2')" '<LAN_IP>,<LAN_IP> <LAN_IP>/<LAN_IP>'
check "loopback, 0.0.0.0, others' public"   "$(run 1 "$OWN" '127.0.0.1:8001 0.0.0.0:80 8.8.8.8')" '127.0.0.1:8001 0.0.0.0:80 8.8.8.8'
check "version strings"                     "$(run 1 "$OWN" 'v0.1.44.1 hub 1.25.1 v10.0.0.1 b10.0.0.1x 172.15.0.1')" 'v0.1.44.1 hub 1.25.1 v10.0.0.1 b10.0.0.1x 172.15.0.1'
check "--no-redact masks nothing"           "$(run 0 "$OWN" 'LANIP=192.168.1.50 10.0.0.7')" 'LANIP=192.168.1.50 10.0.0.7'
if (( fails )); then echo "test-report-redact-ip: $fails failure(s)" >&2; exit 1; fi
echo "test-report-redact-ip: ok"
