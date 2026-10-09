#!/bin/bash
# omacvm check's "Gestures" line tells a helper that waits at start for its
# permissions (it listens by itself once they are granted, #330) from one that
# listens, by its log (gestures_state in src/lib/mac.sh).
#   src/tests/gestures-state.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
expect() {   # NAME WANT (log lines on stdin)
  cat > "$T/log"
  local got; got=$(gestures_state "$T/log")
  if [[ $got == "$2" ]]; then echo "ok   $1"
  else echo "FAIL $1: want '${2//$'\t'/ }', got '${got//$'\t'/ }'"; fails=$((fails + 1)); fi
}
expect "both missing at start" $'waiting\tAccessibility, Input Monitoring' <<'L'
12:08:46 omacvm-gestures: starting (pid 5404)
12:08:46 omacvm-gestures: waiting for Accessibility and Input Monitoring permission
12:08:46 omacvm-gestures: permissions: Accessibility MISSING, Input Monitoring MISSING
12:08:46 omacvm-gestures: cleared what macOS kept of org.omacvm.gestures's Accessibility and Input Monitoring for an older build, so it can ask again (once per build)
L
expect "Accessibility given while waiting, Input Monitoring still off" $'waiting\tInput Monitoring' <<'L'
12:08:46 omacvm-gestures: waiting for Accessibility and Input Monitoring permission
12:08:46 omacvm-gestures: permissions: Accessibility MISSING, Input Monitoring MISSING
12:09:19 omacvm-gestures: permissions: Accessibility granted, Input Monitoring MISSING
L
expect "granted while waiting: listening" listening <<'L'
12:08:46 omacvm-gestures: waiting for Accessibility and Input Monitoring permission
12:08:46 omacvm-gestures: permissions: Accessibility MISSING, Input Monitoring MISSING
12:09:19 omacvm-gestures: permissions: Accessibility granted, Input Monitoring granted
12:09:19 omacvm-gestures: permissions granted
12:09:19 omacvm-gestures: running (escape: Ctrl+Option+Esc)
12:09:19 omacvm-gestures: listening on 127.0.0.1:47830
L
expect "started with its permissions" listening <<'L'
12:09:19 omacvm-gestures: starting (pid 77)
12:09:19 omacvm-gestures: permissions: Accessibility granted, Input Monitoring granted
12:09:19 omacvm-gestures: running (escape: Ctrl+Option+Esc)
L
expect "a helper from before it said so" "" <<'L'
12:09:19 omacvm-gestures: trackpad: built-in
L
# check.sh goes through it, and the helper still logs the lines it reads.
grep -q 'gestures_state "$GESTURES_LOG"' "$R/src/cmd/check.sh" ||
  { echo "FAIL src/cmd/check.sh no longer uses gestures_state"; fails=$((fails + 1)); }
for l in 'waiting for Accessibility and Input Monitoring permission' 'permissions granted' 'listening on %s:%d' 'permissions: Accessibility %s, Input Monitoring %s'; do
  grep -qF "$l" "$R/src/gestures/mac/omacvm-gestures.c" || { echo "FAIL omacvm-gestures.c no longer logs '$l'"; fails=$((fails + 1)); }
done
(( fails == 0 )) && echo "gestures state: all passed" || { echo "gestures state: $fails failed"; exit 1; }
