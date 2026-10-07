#!/bin/bash
# The person's path end to end, before every release (src/release/release.sh
# runs it as a gate; README.md next to this file). On a test Mac, with
# OmacVM.app's test identity ("OmacVM Test", org.omacvm.app.test, its own
# Bridge and Gestures) and a real VM:
#   * the control centre in the VM, driven with real key presses (the real
#     `omacvm` in tmux in the desktop user's session: guest-cc.py);
#   * every switch on and off, the fast network with the VM running and after
#     a restart, Touch ID (the test Bridge's stand-in answers yes or no) with
#     its first request right after a Bridge restart, Graphics, update checks;
#   * the app's window (Accessibility on the launcher's pid: ax.swift): its
#     fast network button, update checks, Update VM;
#   * the update path: the release before (its published zip as the test
#     identity) -> this build through the app's own updater and a local feed
#     signed with a throwaway key, then Update VM, then every switch again.
# Every step checks the control centre's answer, `omacvm vms --json`
# (reachable: true) and the Bridge's log (no refusal, the job ended 0).
#
#   src/tests/e2e/cc-switches.sh --vm NAME [options]
#     --vm NAME          the test VM (in the test app's VMs folder; desktop user logged in by autologin)
#     --clone-from NAME  first make NAME an APFS clone of this stopped test VM (new name and SSH port)
#     --app APP          the build to test, a signed test-identity app: copied over
#                        ~/Applications/"OmacVM Test.app" first (default: the one there)
#     --previous ZIP     the release before (OmacVM-X.Y.Z.zip as published) for the update
#                        path; "latest" downloads releases/latest (gh); default: no update path
#     --only LIST        steps (comma list): prepare,baseline,switches,fastnet,touchid,graphics,
#                        updates,window,update (default: all; update needs --previous)
#     --slow             also the slow switches (thp-kernel, x86-apps: builds in the VM)
#     --features LIST    only these switches (comma list; while working on a fix: never counts for the gate)
#     --out DIR          results (default ~/omacvm-e2e/<time>): summary.tsv, result.json, logs
#     --owner NAME       lock owner name (default cc-e2e)
#     --keep-vm          keep a VM this run cloned (default: deleted at the end)
# With --app, the test app that was installed comes back at the end (other
# tests on this Mac use it) unless OMACVM_E2E_KEEP_APP=1.
# Exit 0 only when every step passed (ok or a skip that says why it does not
# apply on this Mac). FAIL = the product is wrong; BLOCKED = this Mac cannot
# run the step (a person must do something once, e.g. install the fast
# network's service): both fail the gate. result.json carries the app's
# commit; release.sh takes it only for the release commit.
# Stop rules: each step has its own time limit; no retries.
# Never on the person's own Mac session in use: refuses with a battery (the
# MacBook) unless OMACVM_E2E_LAPTOP=1, and when the Mac was used in the last
# 5 minutes; never the person's own app, helpers or VM (fingerprinted before
# and after).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)

VM=""; CLONE=""; NEWAPP=""; PREV=""; ONLY=""; SLOW=0; OUT=""; OWNER=cc-e2e; KEEP=0; FEATS=""
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --clone-from) CLONE=$2; shift 2 ;;
    --app) NEWAPP=$2; shift 2 ;;
    --previous) PREV=$2; shift 2 ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --slow) SLOW=1; shift ;;
    --features) FEATS=",$2,"; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --owner) OWNER=$2; shift 2 ;;
    --keep-vm) KEEP=1; shift ;;
    *) sed -n '19,39s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -n $VM ]] || { sed -n '19,39s/^# \{0,1\}//p' "$0" >&2; exit 2; }
ONLY_ARG=${ONLY:-all}
[[ -n $FEATS ]] && ONLY_ARG="$ONLY_ARG features$FEATS"
want() { [[ -z $ONLY || $ONLY == *",$1,"* ]]; }

APP="$HOME/Applications/OmacVM Test.app"
APPID=org.omacvm.app.test
CLI="$APP/Contents/Resources/omacvm/omacvm"
BRIDGE_APP="$APP/Contents/Helpers/OmacVM Test Bridge.app"
BLOG="$HOME/Library/Logs/omacvm-test-bridge.log"
BDIR="$HOME/Library/Application Support/omacvm-test-bridge"
KEY=$HOME/.ssh/omacvm
OUT=${OUT:-$HOME/omacvm-e2e/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
T0=$(date +%s)
: > "$OUT/summary.tsv"
exec > >(tee -a "$OUT/run.log") 2>&1
export OMACVM_TEST_IDENTITY=1

n_ok=0; n_fail=0; n_blocked=0; n_skip=0
PFX=""   # the pass: "" (this build set up fresh), "update-" (after the update from the release before)
res() {   # STEP ok|FAIL|BLOCKED|skip DETAIL
  printf '%s\t%s\t%s\n' "$PFX$1" "$2" "$3" >> "$OUT/summary.tsv"
  printf '%-34s %-7s %s\n' "$PFX$1" "$2" "$3"
  case $2 in ok) n_ok=$((n_ok + 1)) ;; FAIL) n_fail=$((n_fail + 1)) ;; BLOCKED) n_blocked=$((n_blocked + 1)) ;; *) n_skip=$((n_skip + 1)) ;; esac
  return 0
}
log() { echo "== $(date +%H:%M:%S) $*"; }
CLONES=()   # VMs this run cloned: deleted at the end unless --keep-vm
remove_clones() { local c; for c in ${CLONES[@]+"${CLONES[@]}"}; do (( KEEP )) || rm -rf "$c"; done; CLONES=(); }
die() { echo "cc-switches: $*" >&2; exit 3; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# ---- guards: a test Mac nobody uses right now ----
[[ $(uname -m) == arm64 ]] || die "Apple Silicon only"
[[ -e $HOME/.omacvm-user-testing ]] && die "the person is testing (~/.omacvm-user-testing): no VM now"
if [[ ${OMACVM_E2E_LAPTOP:-} != 1 ]] && ioreg -rc AppleSmartBattery 2>/dev/null | grep -q '"BatteryInstalled" = Yes'; then
  die "this Mac has a battery (a MacBook someone may work on): run it on the test Mac, or OMACVM_E2E_LAPTOP=1"
fi
idle=$(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
(( idle >= 300 || ${OMACVM_E2E_IGNORE_IDLE:-0} == 1 )) || die "someone used this Mac ${idle}s ago: wait until it is idle 5 min"
LOCKS=()
lock() {   # DIR: ours, or taken now (same owner counts: the caller may hold it)
  local o; o=$(cat "$1/owner" 2>/dev/null)
  if mkdir "$1" 2>/dev/null || [[ $o == "$OWNER"* ]]; then
    echo "$OWNER $(date '+%F %T') cc-switches e2e, pid $$" > "$1/owner"; LOCKS+=("$1")
  else
    for l in ${LOCKS[@]+"${LOCKS[@]}"}; do rm -rf "$l"; done
    die "$1 is held: $o"
  fi
}
for l in ${OMACVM_E2E_LOCKS:-$HOME/.omacvm-mini-vm.lock $HOME/.omacvm-test-identity.lock}; do lock "$l"; done

# The person's own helpers, app and VM: the same at the end.
fingerprint() {
  local f
  for f in "$HOME/Applications/OmacVM.app" "/Applications/OmacVM.app" "$HOME/Applications/OmacVMBridge.app" \
           "$HOME/Applications/OmacVMGestures.app" "$HOME/Applications/Omanotch.app"; do
    [[ -e $f ]] && echo "$f $(find "$f" -type f -exec shasum {} + 2>/dev/null | shasum | cut -c1-16)"
  done
  launchctl list 2>/dev/null | awk '$3 ~ /^org\.omacvm\./ && $3 !~ /test/ {print $3}' | sort
  defaults read org.omacvm.app vmsRoot 2>/dev/null
  for f in cli settings.json; do echo "omacvm/$f $(shasum "$HOME/Library/Application Support/omacvm/$f" 2>/dev/null | cut -c1-16)"; done
  ls -ld "$HOME/OmacVM/Omarchy" 2>/dev/null | awk '{print $1, $NF}'
}
fingerprint > "$OUT/fp-before.txt"

QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
qemu_pid() { pgrep -f "$QPAT $VM( |$)" | head -1; }
launcher_pid() { pgrep -f "OmacVM Test.app/Contents/MacOS/OmacVM( |$)" | head -1; }
SERVER=""
cleanup() {
  log "cleanup"
  local p; p=$(qemu_pid)
  if [[ -n $p ]]; then gssh "systemctl poweroff" >/dev/null 2>&1; for _ in $(seq 60); do kill -0 "$p" 2>/dev/null || break; sleep 1; done; kill "$p" 2>/dev/null; fi
  p=$(launcher_pid); [[ -n $p ]] && kill "$p" 2>/dev/null
  [[ -n $SERVER ]] && kill "$SERVER" 2>/dev/null
  rm -f "$BDIR/touchid-test"
  # The update path put the release before (then a relabelled copy) over the test app: this build goes back.
  if [[ -n ${ORIG:-} && -d $ORIG ]]; then rm -rf "$APP"; ditto "$ORIG" "$APP"; fi
  # --app: the test app that was there before.
  if [[ -n ${PRE:-} && -d $PRE && ${OMACVM_E2E_KEEP_APP:-} != 1 ]]; then rm -rf "$APP"; ditto "$PRE" "$APP"; fi
  remove_clones
  fingerprint > "$OUT/fp-after.txt"
  if diff -q "$OUT/fp-before.txt" "$OUT/fp-after.txt" >/dev/null; then res cleanup ok "the person's helpers, app and VM unchanged"
  else res cleanup FAIL "the person's helpers, app or VM changed: diff $OUT/fp-before.txt $OUT/fp-after.txt"; fi
  for l in ${LOCKS[@]+"${LOCKS[@]}"}; do rm -rf "$l"; done
  write_result
  echo; echo "$n_ok ok, $n_fail FAIL, $n_blocked BLOCKED, $n_skip skip in $(( ($(date +%s) - T0) / 60 )) min: $OUT/summary.tsv"
}
write_result() {
  /usr/bin/python3 - "$OUT" "$(plist "$APP" OmacVMCommit)" "$(plist "$APP" CFBundleShortVersionString)" \
    "$n_ok" "$n_fail" "$n_blocked" "$n_skip" "$(( $(date +%s) - T0 ))" "$ONLY_ARG" <<'PY'
import json, sys, time
out, commit, version, ok, fail, blocked, skip, secs, only = sys.argv[1:]
rows = [l.rstrip("\n").split("\t", 2) for l in open(out + "/summary.tsv") if l.strip()]
json.dump({"kind": "omacvm-e2e-cc-switches", "commit": commit, "version": version, "only": only,
           "pass": int(fail) == 0 and int(blocked) == 0 and int(ok) > 0 and only == "all",
           "counts": {"ok": int(ok), "FAIL": int(fail), "BLOCKED": int(blocked), "skip": int(skip)},
           "not_ok": [r for r in rows if len(r) == 3 and r[1] in ("FAIL", "BLOCKED")],
           "seconds": int(secs), "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z")},
          open(out + "/result.json", "w"), indent=1)
PY
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tmo() {   # SECONDS CMD...: macOS has no timeout(1)
  local secs=$1; shift
  "$@" & local p=$! w
  ( sleep "$secs"; kill "$p" 2>/dev/null ) & w=$!
  wait "$p"; local r=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $r
}

# ---- the app ----
if [[ -n $NEWAPP ]]; then
  [[ $(plist "$NEWAPP" CFBundleIdentifier) == "$APPID" ]] || die "$NEWAPP is not the test identity ($APPID)"
  codesign --verify --deep --strict "$NEWAPP" || die "$NEWAPP does not verify"
  [[ -n $(launcher_pid) || -n $(pgrep -f "OmacVM Test.app/Contents/" | head -1) ]] && die "the test app runs: quit it first"
  # The test app other tests on this Mac use comes back at the end.
  PRE=$OUT/app-before/OmacVM\ Test.app
  [[ -d $APP ]] && { mkdir -p "$OUT/app-before"; ditto "$APP" "$PRE"; }
  rm -rf "$APP" && ditto "$NEWAPP" "$APP"
fi
[[ -x $CLI ]] || die "$CLI missing"
codesign --verify --deep --strict "$APP" 2>/dev/null && res app ok "$(plist "$APP" CFBundleShortVersionString) $(plist "$APP" OmacVMCommit | cut -c1-12) team $(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" \
  || res app FAIL "$APP does not verify"
ROOT=$(defaults read "$APPID" vmsRoot 2>/dev/null || echo "$HOME/OmacVM")
VMD=$ROOT/$VM

# ---- tools ----
swiftc -O -o "$OUT/ax" "$HERE/ax.swift" 2> "$OUT/ax-build.log" || res tools FAIL "ax.swift does not build: $OUT/ax-build.log"
vminfo() {   # one VM of `omacvm vms --json`, as "state reachable ip omacvm"
  "$CLI" vms --json 2>/dev/null | /usr/bin/python3 -c '
import json, sys
for v in json.load(sys.stdin).get("vms", []):
    if v.get("name") == sys.argv[1] and v.get("type") == "app":
        print(v.get("state"), str(v.get("reachable")).lower(), v.get("ip") or "-", v.get("omacvm") or "-"); break
else:
    print("missing false - -")' "$VM"
}
IP=""
vssh() {   # ssh to $IP (127.0.0.1:PORT, or the fast network's address)
  local h=${IP%:*} p=22
  [[ $IP == *:* ]] && p=${IP##*:}
  ssh -i "$KEY" -p "$p" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "root@$h" "$@"
}
gssh() {   # the VM as root; the address again from `omacvm vms` when it moved (the fast network)
  local rc=255 i
  [[ -n $IP ]] && { vssh "$@" < /dev/null; rc=$?; }
  (( rc == 255 )) || return $rc
  i=$(vminfo | awk '{print $3}'); [[ $i != - && -n $i ]] || return 255
  IP=$i; vssh "$@" < /dev/null
}
gpush() { gssh true >/dev/null 2>&1; vssh "install -D -m 755 /dev/stdin $1"; }
reachable() {   # SECONDS: `omacvm vms --json` says running + reachable within SECONDS
  local i
  for ((i = 0; i < $1; i += 3)); do [[ $(vminfo | awk '{print $1, $2}') == "running true" ]] && return 0; sleep 3; done
  return 1
}
cc() {   # ARGS...: guest-cc.py in the VM; its JSON in $OUT/cc-<n>.json, a short line on stdout
  CCN=$(( ${CCN:-0} + 1 ))
  local f=$OUT/cc-$CCN-$1.json q="" a
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  gssh "python3 /var/lib/omacvm-e2e/guest-cc.py$q" > "$f" 2> "$f.err"
  local rc=$?
  CCJ=$f
  /usr/bin/python3 - "$f" <<'PY'
import json, sys
try:
    o = json.load(open(sys.argv[1]))
except Exception:
    print("no answer from the VM"); sys.exit(0)
bits = []
for k in ("error", "already", "seconds", "asked"):
    if o.get(k): bits.append(f"{k}: {str(o[k])[:160]}")
for k in ("before", "after"):
    v = o.get(k)
    if isinstance(v, dict): bits.append(f"{k}: {v.get('on')}, {v.get('status')} ({v.get('note', '')[:70]})")
if o.get("trouble"): bits.append("trouble: " + " | ".join(o["trouble"])[:300])
for k in ("got_in", "password_prompt", "linked", "body"):
    if k in o: bits.append(f"{k}: {str(o[k])[:200]}")
print("; ".join(bits))
PY
  return $rc
}
ccok() { /usr/bin/python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") else 1)' "$CCJ" 2>/dev/null; }
# The Bridge's log: what came since a mark (the file may be new after a restart).
bmark() { BMARK=$(stat -f %z "$BLOG" 2>/dev/null || echo 0); }
bsince() { local s; s=$(stat -f %z "$BLOG" 2>/dev/null || echo 0); if (( s < ${BMARK:-0} )); then cat "$BLOG"; else tail -c +$(( ${BMARK:-0} + 1 )) "$BLOG"; fi 2>/dev/null; }
bproblems() {   # refusals and failed jobs since the mark, one line
  bsince | grep -E ': (40[0-9]|41[0-9]|50[0-9])( |$)|unknown-vm|cannot reach|ended [1-9]' | tail -5 | sed 's/^.*omacvm-bridge: //' | tr '\n' '|'
}
guest_feature() { gssh "sed -n 's/^OMACVM_FEATURE_${1//-/_}=//p' /etc/omacvm/env | tail -1"; }
mac_feature() { tr ' ' '\n' < "$VMD/features" 2>/dev/null | sed -n "s/^$1=//p" | tail -1; }
bridge_start() {   # the test Bridge with its log here (as src/mac/install.sh starts it for the test identity)
  pkill -f "OmacVM Test Bridge.app/Contents/MacOS/" 2>/dev/null; sleep 1
  open -g -n --stdout "$BLOG" --stderr "$BLOG" "$BRIDGE_APP"
  local i; for ((i = 0; i < 20; i++)); do lsof -nP -iTCP:47931 -sTCP:LISTEN >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}
start_vm() {
  local i
  for ((i = 0; i < 60; i++)); do [[ -z $(qemu_pid) ]] && break; sleep 1; done
  # The VM's clipboard on a pasteboard of its own, never the Mac's (STANDARDS 25).
  open -n -g --env OMACVM_TEST_PASTEBOARD=org.omacvm.test.e2e "$APP" --args --start --vm "$VM"
  for ((i = 0; i < 40; i++)); do [[ -n $(qemu_pid) ]] && break; sleep 1; done
  [[ -n $(qemu_pid) ]] || return 1
  for ((i = 0; i < 90; i++)); do gssh "test -d /run/user/\$(id -u \$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env))/hypr" 2>/dev/null && { sleep 5; return 0; }; sleep 2; done
  return 1
}
stop_vm() {   # as the person: shut down in Omarchy; QEMU and the launcher go
  local p i; p=$(qemu_pid); [[ -n $p ]] || return 0
  gssh "systemctl poweroff" >/dev/null 2>&1
  for ((i = 0; i < 90; i++)); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -0 "$p" 2>/dev/null && return 1
  for ((i = 0; i < 15; i++)); do [[ -z $(launcher_pid) ]] && break; sleep 1; done
  return 0
}
restart_vm() { stop_vm && start_vm && reachable 60 && cc start 120 > /dev/null && ccok; }
window() {   # the launcher's window on this VM (the VM must be stopped): its pid, or nothing
  local i p
  close_window   # a launcher from before keeps the VM it shows
  open -n -g "$APP" --args --vm "$VM"
  for ((i = 0; i < 20; i++)); do
    p=$(launcher_pid)
    if [[ -n $p && $("$OUT/ax" "$p" dump 2>/dev/null | head -1) == "windows: "[1-9]* ]]; then
      sleep 1
      # Never press anything in a window that shows another VM (a kept one of another test).
      "$OUT/ax" "$p" text 2>/dev/null | grep -qF "$VM" || { echo "the window shows another VM" >&2; return 1; }
      echo "$p"; return 0
    fi
    sleep 1
  done
  return 1
}
close_window() { local p; p=$(launcher_pid); [[ -n $p ]] && kill "$p" 2>/dev/null; sleep 2; }


# ---- the VM ----
appver() { cat "$APP/Contents/Resources/omacvm/src/VERSION" 2>/dev/null || cat "$APP/Contents/Resources/omacvm/VERSION" 2>/dev/null; }
# The fast network's service for this app: ok | old | down | missing | stopped (src/net/mac/install.sh).
netd() { "$APP/Contents/Resources/omacvm/src/net/mac/install.sh" --status --app "$APP" 2>/dev/null | head -1; }
# Switching it needs root only when the service is not there for this app; nobody types a password here.
netd_blocked() { local s; s=$(netd); [[ $s == missing || $s == down ]] && ! sudo -n true 2>/dev/null && echo "omacvm-netd is $s for this app and nobody can type the administrator's password here: install it once (README)"; }
use_vm() {   # NAME [CLONE_FROM]: the VM of this pass (an APFS clone of a kept one, new name and SSH port)
  VM=$1; VMD=$ROOT/$VM; IP=""
  if [[ -n ${2:-} ]]; then
    log "clone $2 -> $VM"
    [[ -e $VMD ]] && die "$VMD exists"
    [[ -f $ROOT/$2/vm.env ]] || die "no VM $2 in $ROOT"
    pgrep -f "$QPAT $2( |$)" >/dev/null && die "$2 runs: stop it first"
    cp -cR "$ROOT/$2" "$VMD" || die "clone failed"
    CLONES+=("$VMD")
    rm -f "$VMD/fast-network" "$VMD"/logs/*.pid
    local port=$(( 52500 + RANDOM % 400 ))
    sed -i '' "s/^NAME=.*/NAME='$VM'/; s/^SSH_PORT=.*/SSH_PORT=$port/" "$VMD/vm.env"
    res clone ok "$2 -> $VM (APFS clone, SSH port $port)"
  fi
  [[ -f $VMD/vm.env && -e $VMD/ready ]] || die "no finished VM $VM in $ROOT"
  [[ -n $(qemu_pid) ]] && die "$VM runs already: shut it down first"
  pgrep -f "$QPAT" >/dev/null && die "another test VM runs (one at a time)"
  return 0
}

update_vm_window() {   # Update VM in the app's window (VM stopped): 0 when the VM has this app's OmacVM
  local p t0 i v want
  want=$(appver); t0=$(date +%s)
  rm -f "$VMD/logs/update.log"
  p=$(window) || { echo "no window on $VM"; return 1; }
  if ! "$OUT/ax" "$p" press "Update VM" > "$OUT/ax-update-vm.txt" 2>&1; then
    close_window
    v=$(cat "$VMD/omacvm-version" 2>/dev/null)
    if [[ -n $v && $(printf '%s\n%s\n' "$v" "$want" | sort -V | tail -1) == "$v" ]]; then
      echo "no Update VM button: the VM has $v already (this app: $want)"; return 0
    fi
    echo "no Update VM button ($(cat "$OUT/ax-update-vm.txt")); the VM has ${v:-nothing}, the app $want"; return 1
  fi
  for ((i = 0; i < 1500; i += 5)); do
    grep -q "^UPDATED " "$VMD/logs/update.log" 2>/dev/null && [[ -z $(qemu_pid) ]] && break
    sleep 5
  done
  close_window
  v=$(cat "$VMD/omacvm-version" 2>/dev/null)
  echo "Update VM: $(tail -1 "$VMD/logs/update.log" 2>/dev/null | cut -c1-100); omacvm-version $v; $(( $(date +%s) - t0 )) s"
  [[ $v == "$want" ]]
}

feat() {   # FIELD NAME, from this pass's `omacvm features --json`
  /usr/bin/python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["features"]:
    if f["name"] == sys.argv[3]: print(str(f[sys.argv[2]]).lower() if isinstance(f[sys.argv[2]], bool) else f[sys.argv[2]])' "$OUT/${PFX}features.json" "$1" "$2"
}
read_features() {
  "$CLI" features --vm "$VM" --json > "$OUT/${PFX}features.json" 2> "$OUT/${PFX}features.err"
  names=$(/usr/bin/python3 -c 'import json,sys; print(" ".join(f["name"] for f in json.load(open(sys.argv[1]))["features"]))' "$OUT/${PFX}features.json" 2>/dev/null)
  [[ -n $names ]] || res features FAIL "omacvm features --json gave nothing: $(tail -2 "$OUT/${PFX}features.err")"
}
features_as_new() {   # what a new VM has on that this one has off (a clone of a kept VM): on, as a person would
  local need
  need=$(/usr/bin/python3 -c '
import json, sys
print(" ".join(f["name"] for f in json.load(open(sys.argv[1]))["features"]
               if str(f.get("default")).lower() in ("true", "on") and f.get("available") and not f.get("on")))' "$OUT/${PFX}features.json")
  [[ -n $need ]] || return 0
  log "omacvm enable $need (limit 30 min)"
  # One feature name per word.
  # shellcheck disable=SC2086
  if tmo 1800 "$CLI" enable $need --vm "$VM" --yes > "$OUT/${PFX}enable.log" 2>&1; then res features-as-new ok "turned on as a new VM has them: $need"
  else res features-as-new FAIL "omacvm enable $need: $(tail -2 "$OUT/${PFX}enable.log" | tr '\n' ' ')"; fi
  read_features
}
start_pass() {   # start the VM, the control centre's driver into it, the features
  log "start $VM"
  if start_vm && reachable 90; then res start ok "running, reachable: $(vminfo)"
  else res start FAIL "the VM did not come up: $(vminfo)"; return 1; fi
  gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py" || res tools FAIL "could not copy guest-cc.py into the VM"
  read_features
  features_as_new
  BASE=$(cat "$VMD/features" 2>/dev/null)
}

baseline() {   # TAG: the control centre comes up linked; no row fails; the Mac reaches the VM
  local s bad
  s=$(cc start 120)
  if ccok; then
    bad=$(/usr/bin/python3 -c '
import json, re, sys
o = json.load(open(sys.argv[1]))
print(" | ".join(l.strip(" │")[:90] for l in o["screen"].splitlines() if re.search("|", l))[:600])' "$CCJ")
    [[ -z $bad ]] && res "baseline-$1" ok "$s" || res "baseline-$1" FAIL "rows failing or needing a person: $bad"
  else
    res "baseline-$1" FAIL "$s"
  fi
  reachable 30 && res "reachable-$1" ok "$(vminfo)" || res "reachable-$1" FAIL "$(vminfo)"
}

switch_one() {   # NAME on|off: one press in the control centre, and every check
  local n=$1 to=$2 title s t0 b g m job why=""
  title=$(feat title "$n")
  bmark; t0=$(date +%s)
  s=$(cc toggle "$title" "$to" 900)
  b=$(bproblems); g=$(guest_feature "$n"); m=$(mac_feature "$n")
  job=$(bsince | grep -E "job [^ ]+ \((enable|disable) [^)]*\b$n\b" | tail -1 | sed 's/^.*control: //')
  ccok || why+="cc: $s; "
  reachable 60 || why+="not reachable: $(vminfo); "
  [[ -n $b ]] && why+="Bridge: $b; "
  [[ $g == "$to" ]] || why+="the VM's /etc/omacvm/env says ${g:-nothing}; "
  [[ $m == "$to" ]] || why+="the VM folder's features says ${m:-nothing}; "
  [[ $s == *already* || $job == *"ended 0"* ]] || why+="no job ended 0 in the Bridge's log (${job:-none}); "
  if [[ -z $why ]]; then res "switch-$n-$to" ok "$(( $(date +%s) - t0 )) s; $job"
  else res "switch-$n-$to" FAIL "$why(screen: $CCJ)"; fi
}

restore_base() {   # what a switch changed through its dependencies, back as before (through the cc too)
  local w n v now
  for w in $BASE; do
    n=${w%%=*}; v=${w#*=}
    case $n in fast-network|touch-id|thp-kernel|x86-apps|control-centre) continue ;; esac
    now=$(mac_feature "$n")
    [[ -n $now && $now != "$v" && $(feat available "$n") == true ]] && switch_one "$n" "$v"
  done
  return 0
}

step_switches() {
  log "switches (limit 90 min)"
  local n title s on other g rc
  for n in $names; do
    [[ -z $FEATS || $FEATS == *",$n,"* ]] || continue
    case $n in
      fast-network|touch-id|control-centre) continue ;;   # their own steps
      thp-kernel|x86-apps) (( SLOW )) || { res "switch-$n" skip "slow (a build in the VM): --slow"; continue; } ;;
    esac
    if [[ $(feat available "$n") != true ]]; then
      # Not for this Mac or VM: the row says so and Space changes nothing.
      title=$(feat title "$n")
      s=$(cc row "$title")
      [[ $s == *unavailable* || $s == *"off, off"* || $s == *"no row"* ]] \
        && res "switch-$n" skip "not on this Mac ($(feat reason "$n")); row: ${s:0:120}" \
        || res "switch-$n" FAIL "unavailable here ($(feat reason "$n")) but the row says: $s"
      continue
    fi
    on=$(mac_feature "$n"); [[ -n $on ]] || on=$(feat on "$n" | sed 's/true/on/; s/false/off/')
    other=$([[ $on == on ]] && echo off || echo on)
    switch_one "$n" "$other"
    switch_one "$n" "$on"
    restore_base
  done
  [[ -z $FEATS || $FEATS == *",control-centre,"* ]] || return 0
  # The control centre itself: off closes it (asked first); the Mac brings it back.
  bmark
  s=$(cc toggle "OmacVM control centre" off 600)
  g=$(guest_feature control-centre)
  if [[ $g == off ]] && ! gssh "test -x /usr/local/bin/omacvm"; then res switch-control-centre-off ok "${s:0:160}"
  else res switch-control-centre-off FAIL "env ${g:-?}; $s"; fi
  tmo 900 "$CLI" enable control-centre --vm "$VM" --yes > "$OUT/${PFX}enable-cc.log" 2>&1; rc=$?
  gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py"
  if (( rc == 0 )); then baseline after-control-centre-back
  else res switch-control-centre-on FAIL "omacvm enable control-centre: exit $rc ($OUT/${PFX}enable-cc.log)"; fi
}

netcheck() { gssh "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://archlinux.org" 2>/dev/null; }
step_fastnet() {   # the fast network: while the VM runs, and after a restart
  log "fast network (limit 30 min)"
  local st blk to s why b net wantnet
  if [[ $(feat available fast-network) != true ]]; then res fastnet BLOCKED "not available here: $(feat reason fast-network)"; return; fi
  st=$(netd); blk=$(netd_blocked)
  if [[ -n $blk ]]; then res fastnet BLOCKED "$blk"; return; fi
  for to in on off; do
    bmark
    s=$(cc toggle "Fast network" "$to" 600)
    sleep 10
    why=""
    ccok || why+="cc: $s; "
    reachable 60 || why+="not reachable: $(vminfo); "
    [[ $(netcheck) == 200 ]] || why+="no internet in the VM; "
    b=$(bproblems); [[ -n $b ]] && why+="Bridge: $b; "
    if [[ -z $why ]]; then res "fastnet-running-$to" ok "${s:0:160}; network now: $(head -1 "$VMD/logs/network" 2>/dev/null)"
    else res "fastnet-running-$to" FAIL "${why}netd: $st"; fi
    bmark
    if restart_vm; then
      net=$(head -1 "$VMD/logs/network" 2>/dev/null)
      wantnet=$([[ $to == on ]] && echo vmnet || echo user)
      why=""
      [[ $net == *"$wantnet"* ]] || why+="logs/network says '$net', want $wantnet; "
      [[ $(netcheck) == 200 ]] || why+="no internet in the VM; "
      b=$(bproblems); [[ -n $b ]] && why+="Bridge: $b; "
      [[ -z $why ]] && res "fastnet-restart-$to" ok "$net; $(vminfo)" || res "fastnet-restart-$to" FAIL "$why"
    else
      res "fastnet-restart-$to" FAIL "the VM or its control centre did not come back: $(vminfo)"
    fi
  done
}

step_touchid() {   # Touch ID: the test Bridge's stand-in answers (README)
  log "Touch ID (limit 20 min)"
  local s b
  if [[ $(feat available touch-id) != true ]]; then res touchid BLOCKED "not available here: $(feat reason touch-id)"; return; fi
  echo yes > "$BDIR/touchid-test"
  bmark
  s=$(cc toggle "Touch ID" on 600)
  ccok && res touchid-on ok "${s:0:200}" || res touchid-on FAIL "after the switch, before a restart: $s"
  if restart_vm; then
    bmark; s=$(cc sudo yes 60)
    ccok && [[ $(bsince) == *"sudo yes (test stand-in"* ]] && res touchid-yes ok "${s:0:120}" \
      || res touchid-yes FAIL "$s; Bridge: $(bsince | grep -E 'touchid|unknown-vm' | tail -2 | tr '\n' '|')"
    echo no > "$BDIR/touchid-test"
    bmark; s=$(cc sudo no 60)
    ccok && res touchid-no ok "the password prompt: ${s:0:120}" || res touchid-no FAIL "$s; Bridge: $(bsince | grep touchid | tail -2 | tr '\n' '|')"
    echo yes > "$BDIR/touchid-test"
    # The first request right after a Bridge restart (enable touch-id restarts the installed Bridge).
    bmark; bridge_start; s=$(cc sudo yes 60)
    b=$(bsince | grep -E 'touchid|unknown-vm|409' | tail -3 | tr '\n' '|')
    ccok && [[ $b != *unknown-vm* && $b != *" 409"* ]] && res touchid-after-bridge-restart ok "${s:0:120}" \
      || res touchid-after-bridge-restart FAIL "$s; Bridge: $b"
  else
    res touchid-restart FAIL "the VM or its control centre did not come back after Touch ID on: $(vminfo)"
  fi
  bmark
  s=$(cc toggle "Touch ID" off 600)
  ccok && res touchid-off ok "${s:0:160}" || res touchid-off FAIL "$s"
  if restart_vm; then
    s=$(cc sudo no 60)
    ccok && res touchid-off-password ok "off: the password as before" || res touchid-off-password FAIL "$s"
  else res touchid-off-restart FAIL "$(vminfo)"; fi
  rm -f "$BDIR/touchid-test"
}

graphics_mac() { "$CLI" graphics --vm "$VM" --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; o=json.load(sys.stdin); print(o.get("graphics"), o.get("next_start"), "|", o.get("this_start"))' 2>/dev/null; }
step_graphics() {   # each choice from the control centre; the Mac agrees; Vulkan after a restart
  log "Graphics (limit 40 min)"
  local g0 to s m b
  g0=$(graphics_mac | awk '{print $1}')
  for to in opengl vulkan auto; do
    bmark
    s=$(cc graphics "$to" 1500)
    m=$(graphics_mac); b=$(bproblems)
    if ccok && [[ $m == "$to "* && -z $b ]] && reachable 30; then res "graphics-$to" ok "Mac: $m"
    else res "graphics-$to" FAIL "cc: ${s:0:200}; Mac: $m; Bridge: $b"; fi
    if [[ $to == vulkan ]]; then
      if restart_vm; then
        m=$(graphics_mac)
        [[ ${m#*|} == *"-> vulkan"* ]] && res graphics-vulkan-start ok "$m" || res graphics-vulkan-start FAIL "after a restart (this start should be Vulkan): $m"
      else res graphics-vulkan-start FAIL "the VM or its control centre did not come back: $(vminfo)"; fi
    fi
  done
  [[ -n $g0 && $g0 != auto ]] && cc graphics "$g0" 1500 > /dev/null
  return 0
}

step_updates() {   # the control centre's update check, and the Bridge's log
  log "update checks (limit 5 min)"
  local s b
  bmark
  s=$(cc updates 180)
  b=$(bsince | grep -E 'update check' | tail -1 | sed 's/^.*control: //')
  if ccok && [[ $b == *"update check: "*parts* ]]; then res updates-cc ok "Bridge: $b"
  else res updates-cc FAIL "cc: ${s:0:300}; Bridge: ${b:-no update check}"; fi
}

step_window() {   # the app's window (the VM stopped): update checks, the fast network button
  log "the app's window (limit 10 min)"
  local p e was now lbl k blk
  stop_vm || res window-stop FAIL "the VM did not shut down"
  if ! p=$(window); then res window FAIL "the app's window did not show $VM"; start_vm; return; fi
  "$OUT/ax" "$p" text > "$OUT/${PFX}window-before.txt" 2>&1
  "$OUT/ax" "$p" press "Check Now" > "$OUT/${PFX}ax-check.txt" 2>&1 && sleep 15
  "$OUT/ax" "$p" text > "$OUT/${PFX}window-check.txt" 2>&1
  e=$(grep -iE 'could not|failed|not signed|refused|error' "$OUT/${PFX}window-check.txt" | head -2 | tr '\n' '|')
  [[ -z $e && $(cat "$OUT/${PFX}ax-check.txt") == pressed* ]] && res window-check-now ok "$(grep -iE 'up to date|is ready|checked|newest' "$OUT/${PFX}window-check.txt" | head -1)" \
    || res window-check-now FAIL "$(cat "$OUT/${PFX}ax-check.txt"); $e"
  if "$OUT/ax" "$p" has "Turn On…" >/dev/null 2>&1 || "$OUT/ax" "$p" has "Turn Off…" >/dev/null 2>&1; then
    blk=$(netd_blocked)
    if [[ -n $blk ]]; then
      res window-fastnet BLOCKED "$blk"
    else
      was=$([[ -s $VMD/fast-network ]] && echo on || echo off)
      for k in 1 2; do
        lbl=$([[ -s $VMD/fast-network ]] && echo "Turn Off…" || echo "Turn On…")
        "$OUT/ax" "$p" press "$lbl" > "$OUT/${PFX}ax-fastnet-$k.txt" 2>&1; sleep 8
        now=$([[ -s $VMD/fast-network ]] && echo on || echo off)
        [[ $now != "$was" && $(mac_feature fast-network) == "$now" ]] && res "window-fastnet-$now" ok "$lbl -> the VM's fast-network file and record: $now" \
          || res "window-fastnet-$k" FAIL "$lbl: file $now, record $(mac_feature fast-network) ($(cat "$OUT/${PFX}ax-fastnet-$k.txt"); $("$OUT/ax" "$p" text | grep -iE 'fast|password|could' | head -2 | tr '\n' '|'))"
        was=$now
      done
    fi
  else
    res window-fastnet FAIL "no fast network button in the window"
  fi
  close_window
  start_vm && reachable 60 || res window-start FAIL "$(vminfo)"
}

steps() {   # every step on the running VM of this pass
  want baseline && { log "baseline"; baseline start; }
  want switches && step_switches
  want fastnet && step_fastnet
  want touchid && step_touchid
  want graphics && step_graphics
  want updates && step_updates
  want window && step_window
  stop_vm || res stop FAIL "the VM did not shut down"
  return 0
}

mkdir -p "$BDIR"; rm -f "$BDIR/touchid-test"
bridge_start || res bridge FAIL "the test Bridge does not listen on 47931 ($BLOG)"

# ---- pass 1: this build, a VM brought to it with Update VM ----
if [[ $ONLY != ",update," ]]; then
  use_vm "$VM" "$CLONE"
  if want prepare; then
    log "prepare: Update VM in the window (limit 25 min)"
    if d=$(update_vm_window); then res update-vm ok "$d"; else res update-vm FAIL "$d"; fi
  fi
  start_pass && steps
  remove_clones
fi

# ---- pass 2: the release before -> this build through the app's updater, Update VM, every step again ----
if [[ -n $PREV ]] && want update; then
  log "update path (limit 60 min, then every step again)"
  PFX=update-
  ORIG=$OUT/orig/OmacVM\ Test.app CAND=$OUT/candidate/OmacVM\ Test.app
  mkdir -p "$OUT/orig" "$OUT/candidate"; ditto "$APP" "$ORIG"; ditto "$APP" "$CAND"
  if [[ $PREV == latest ]]; then
    gh release download -R gillesgoetsch/OmacVM -p 'OmacVM-*.zip' -D "$OUT/prev" --clobber >/dev/null 2>&1 && PREV=$(ls "$OUT"/prev/OmacVM-*.zip | head -1)
  fi
  if [[ ! -f $PREV ]]; then res previous BLOCKED "no zip of the release before ($PREV)"
  elif ! "$HERE/relabel.sh" "$PREV" "$OUT/prev-app" > "$OUT/relabel.log" 2>&1; then res previous FAIL "relabel.sh: $OUT/relabel.log"
  else
    PV=$(plist "$OUT/prev-app/OmacVM Test.app" CFBundleShortVersionString)
    CV=$(plist "$CAND" CFBundleShortVersionString)
    if [[ $PV == "$CV" || $(printf '%s\n%s\n' "$PV" "$CV" | sort -V | tail -1) != "$CV" ]]; then
      # Before the release commit this build still says the version before: one patch above, for the updater only.
      CV=${PV%.*}.$(( ${PV##*.} + 1 ))
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CV" -c "Set :CFBundleVersion $CV" "$CAND/Contents/Info.plist"
      codesign --force --sign "${OMACVM_SIGN_ID:?OMACVM_SIGN_ID: the Developer ID to sign the candidate again}" --options runtime \
        --preserve-metadata=entitlements,identifier "$CAND" 2>> "$OUT/relabel.log"
      res version skip "this build says $PV like the release before: offered to the updater as $CV"
    fi
    # The release before, and a VM it set up (Update VM in its window).
    rm -rf "$APP"; ditto "$OUT/prev-app/OmacVM Test.app" "$APP"
    bridge_start
    if [[ -n $CLONE ]]; then use_vm "$VM-u" "$CLONE"; else use_vm "$VM"; fi
    if d=$(update_vm_window); then res previous-update-vm ok "$PV: $d"; else res previous-update-vm FAIL "$PV: $d"; fi
    if start_vm && reachable 90; then
      gpush /var/lib/omacvm-e2e/guest-cc.py < "$HERE/guest-cc.py"
      baseline previous
    else res previous-start FAIL "$(vminfo)"; fi
    stop_vm
    # A local feed, signed with a throwaway key (test builds take OMACVM_APPCAST_KEY).
    F=$OUT/feed; mkdir -p "$F"
    swift "$R/src/release/sign.swift" keygen "$F/key" > "$F/key.pub" 2>/dev/null
    (cd "$OUT/candidate" && ditto -c -k --keepParent "OmacVM Test.app" "$F/OmacVM-$CV.zip")
    TEAM=$(codesign -dv "$CAND" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    PORT=$(( 18800 + RANDOM % 400 ))
    printf '{"schema": 1, "kind": "app-feed", "version": "%s", "url": "http://127.0.0.1:%s/OmacVM-%s.zip", "length": %s, "sha256": "%s", "minimum_macos": "15.0", "devid_teams": ["%s"]}\n' \
      "$CV" "$PORT" "$CV" "$(stat -f %z "$F/OmacVM-$CV.zip")" "$(shasum -a 256 "$F/OmacVM-$CV.zip" | cut -d' ' -f1)" "$TEAM" > "$F/OmacVM-appcast.json"
    swift "$R/src/release/sign.swift" sign "$F/key" "$F/OmacVM-appcast.json" > "$F/OmacVM-appcast.json.sig"
    /usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$F" > "$OUT/feed-server.log" 2>&1 & SERVER=$!
    sleep 1
    # The app updates itself (as the window's "Update to X" does, without the window: --update-now).
    close_window
    open -n -g --env "OMACVM_APPCAST_URL=http://127.0.0.1:$PORT/OmacVM-appcast.json" --env "OMACVM_APPCAST_KEY=$(cat "$F/key.pub")" \
      "$APP" --args --update-now
    for ((i = 0; i < 300; i += 5)); do [[ $(plist "$APP" CFBundleShortVersionString) == "$CV" ]] && break; sleep 5; done
    sleep 10; close_window
    UPD=$(ls -dt "$HOME/Library/Application Support/OmacVM/Updates/$APPID"/*/ 2>/dev/null | head -1)
    if [[ $(plist "$APP" CFBundleShortVersionString) == "$CV" ]] && codesign --verify --deep --strict "$APP" 2>/dev/null; then
      res app-self-update ok "$PV -> $CV through the app's updater: $(grep 'result:' "$UPD/update.log" 2>/dev/null | tail -1)"
      bridge_start   # this build's Bridge (an installed app restarts it when its helpers change)
      if d=$(update_vm_window); then res update-vm ok "$d"; else res update-vm FAIL "$d"; fi
      ONLY=""   # every step again on the updated VM
      start_pass && steps
    else
      res app-self-update FAIL "still $(plist "$APP" CFBundleShortVersionString): $(tail -3 "$UPD/update.log" 2>/dev/null | tr '\n' '|')"
    fi
  fi
  remove_clones
fi
(( n_fail == 0 && n_blocked == 0 ))
