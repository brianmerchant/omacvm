#!/bin/bash
# omacvm check finds the Bridge and Gestures by their process, whichever job
# started them (their LaunchAgent, or macOS again after a grant: an
# application.<id>.* job, #331), and reads only what the running one logged:
# a log from a process before it says nothing about it.
#   src/tests/helper-running.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
T=$(mktemp -d)
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"' EXIT
fails=0
pass() { echo "ok   $1"; }
failed() { echo "FAIL $1"; fails=$((fails + 1)); }

# A stand-in Bridge, started outside launchd as macOS would (not its LaunchAgent).
mkdir -p "$T/OmacVMBridge.app/Contents/MacOS"
printf '#!/bin/bash\nexec sleep 60\n' > "$T/OmacVMBridge.app/Contents/MacOS/omacvm-bridge"
chmod +x "$T/OmacVMBridge.app/Contents/MacOS/omacvm-bridge"
/bin/bash "$T/OmacVMBridge.app/Contents/MacOS/omacvm-bridge" &
FAKE=$!; PIDS="$PIDS $FAKE"; disown "$FAKE" 2>/dev/null || true
sleep 1
got=$(helper_pid bridge)
[[ -n $got ]] && [[ $(ps -o args= -p "$got") == *OmacVMBridge.app/Contents/MacOS/omacvm-bridge* ]] &&
  { [[ $got == "$FAKE" ]] || (( $(proc_started "$got") <= $(proc_started "$FAKE") )); } &&
  pass "a Bridge outside its LaunchAgent is found (pid $got; the oldest, when this Mac runs its own)" ||
  failed "helper_pid bridge: got '$got', the stand-in is $FAKE"
[[ -z $(helper_pid gestures test 2>/dev/null | grep -x "$FAKE") ]] && pass "not taken for the test identity's Gestures" ||
  failed "the stand-in Bridge was taken for the test Gestures"
# The Bridge runs omacvm check itself (the control centre's status), and pgrep
# leaves its own ancestors out unless -a: the Bridge then never found itself.
mkdir -p "$T/bin"; printf '#!/bin/bash\necho "$*" > "%s/pgrep-args"\n' "$T" > "$T/bin/pgrep"; chmod +x "$T/bin/pgrep"
PATH="$T/bin:$PATH" helper_pid bridge >/dev/null || true
[[ " $(cat "$T/pgrep-args" 2>/dev/null) " == *" -a "* ]] && pass "pgrep -a: found also when omacvm check runs as the Bridge's child" ||
  failed "helper_pid's pgrep leaves out ancestors (args: $(cat "$T/pgrep-args" 2>/dev/null))"
helper_pid nothing >/dev/null 2>&1 && failed "helper_pid takes an unknown helper" || pass "an unknown helper: none"

# proc_started: a process that started a moment ago.
s=$(proc_started "$FAKE"); now=$(date +%s)
(( s <= now && now - s < 30 )) && pass "proc_started: within the last seconds" || failed "proc_started: $s (now $now)"

# #331: the log is the one of the process before (macOS started this one again,
# its output to /dev/null): nothing of it is taken.
cat > "$T/log" <<L
2026-10-09 12:08:46 omacvm-bridge: starting (pid 5275, token x)
2026-10-09 12:08:46 omacvm-bridge: permissions: Accessibility MISSING, Input Monitoring MISSING
2026-10-09 12:08:46 omacvm-bridge: media keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)
L
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$T/log"
if out=$(helper_log "$FAKE" "$T/log"); then failed "an older process's log was taken: $out"; else pass "the log of the process before: not taken (exit 1)"; fi
# The running one said it started: only its own lines.
cat >> "$T/log" <<L
2026-10-09 12:09:11 omacvm-bridge: starting (pid $FAKE, token x)
2026-10-09 12:09:11 omacvm-bridge: permissions: Accessibility granted, Input Monitoring granted
2026-10-09 12:09:11 omacvm-bridge: media keys: event tap armed (made while a VM is in front)
L
out=$(helper_log "$FAKE" "$T/log")
[[ $out != *MISSING* && $out == *"permissions: Accessibility granted"* && $(head -1 <<<"$out") == *"starting (pid $FAKE,"* ]] &&
  pass "its own lines only, from its 'starting (pid N' line" || failed "helper_log took: $out"
# Gestures says "starting (pid N)" too.
printf '20:00:00 omacvm-gestures: starting (pid 1)\n20:00:01 omacvm-gestures: starting (pid %s)\n20:00:02 omacvm-gestures: running\n' "$FAKE" > "$T/glog"
[[ $(helper_log "$FAKE" "$T/glog" | wc -l | tr -d ' ') == 2 ]] && pass "Gestures' own lines from its start" || failed "Gestures' lines: $(helper_log "$FAKE" "$T/glog")"
# A helper from before it said so, writing since it started: its log as before.
printf '20:00:02 omacvm-gestures: trackpad: built-in\n' > "$T/old"
[[ $(helper_log "$FAKE" "$T/old") == *"trackpad: built-in"* ]] && pass "an older helper writing now: its log as before" || failed "older helper's fresh log not taken"

# check.sh uses them for both helpers.
grep -q 'helper_pid bridge' "$R/src/cmd/check.sh" && grep -q 'helper_pid gestures' "$R/src/cmd/check.sh" &&
  grep -q 'helper_log "$BRIDGE_PID" "$BRIDGE_LOG"' "$R/src/cmd/check.sh" && grep -q 'helper_log "$GESTURES_PID" "$GESTURES_LOG"' "$R/src/cmd/check.sh" &&
  pass "check.sh finds both by process and reads their current lines" || failed "check.sh no longer uses helper_pid/helper_log"
# Both helpers log their start with their pid, and write to their log when macOS started them (/dev/null).
grep -qF 'starting (pid \(getpid())' "$R/src/bridge/mac/main.swift" && grep -qF 'logToFile()' "$R/src/bridge/mac/main.swift" &&
  grep -qF 'logf_("starting (pid %d)"' "$R/src/gestures/mac/omacvm-gestures.c" && grep -qF '  logToFile();' "$R/src/gestures/mac/omacvm-gestures.c" &&
  pass "both helpers log 'starting (pid N' and write their own log" || failed "a helper no longer logs its start or its own log"
(( fails == 0 )) && echo "helper running: all passed" || { echo "helper running: $fails failed"; exit 1; }
