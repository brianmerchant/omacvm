#!/bin/bash
# Idle power of the whole Mac, for the final round.
#   idle-power.sh TARGET [--seconds 600] [--settle 60] [--ssh USER@HOST[:PORT]] [--desktop TEXT] OUT.jsonl
# TARGET: mac, app, utm, fusion or parallels (the label; the VM must already
# run alone in full screen with its desktop idle, see README.md). --ssh: the
# VM, checked once before the settle (no Chrome left, load low). The VM
# process's CPU time is read at the start and the end of the window (no
# polling), so an idle VM that is not idle shows. --desktop: what the screen
# shows, recorded (the built-in display dims per zone: use the same dark
# wallpaper everywhere).
# Reads SystemPowerIn (mW) from AppleSmartBattery every 5 s (macOS updates it
# about once a minute, so 10 minutes give about 10 readings): the power coming
# in from the charger, which is the whole Mac's draw while it is on the
# charger and NOT charging. It refuses to start while the Mac charges or runs
# on battery, and the window is marked invalid if charging starts during it.
# The battery's own average (AccumulatedSystemLoad, as power.sh) over the same
# window is recorded too, as a cross-check. One long wait: don't touch the Mac.
# The display stays on (caffeinate -d); its brightness is read, never set.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
TARGET=${1:-}; shift 2>/dev/null
SECS=600; SETTLE=60; SSH_DEST=""; DESKTOP=""
while [ "${1:-}" != "${1#--}" ]; do
  case $1 in
    --seconds) SECS=$2; shift 2 ;;
    --settle) SETTLE=$2; shift 2 ;;
    --ssh) SSH_DEST=$2; shift 2 ;;
    --desktop) DESKTOP=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
OUT=${1:-}
[ -n "$TARGET" ] && [ -n "$OUT" ] || { sed -n '2,4p' "$0" >&2; exit 2; }
case $TARGET in
  mac) KEEP_VM=NONE ;; app) KEEP_VM='OmacVM[^/]*\.app/' ;; utm) KEEP_VM='UTM\.app/|com\.apple\.Virtualization' ;;
  fusion) KEEP_VM='VMware Fusion\.app/' ;; parallels) KEEP_VM='Parallels Desktop\.app/|/prl_' ;;
  *) die "target is mac, app, utm, fusion or parallels" ;;
esac
export KEEP_VM
[ "$(battery ExternalConnected)" = Yes ] || die "the charger is not connected: SystemPowerIn reads 0 on battery"
preflight "$KEEP_VM"
GUEST=null
if [ -n "$SSH_DEST" ]; then   # one look into the VM: the round's Chrome gone, the desktop idle
  port=22 host=$SSH_DEST
  case $host in *:*) port=${host##*:}; host=${host%:*} ;; esac
  GUEST=$(ssh -i "$HOME/.ssh/omacvm" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$host" \
    'printf "{\"chrome\":%s,\"load1\":%s}" "$(pgrep -c -f /opt/google/chrome/chrome || true)" "$(cut -d" " -f1 /proc/loadavg)"' </dev/null) ||
    die "no SSH to $SSH_DEST"
  case $GUEST in *'"chrome":0'*) ;; *) die "Chrome still runs in the VM ($GUEST): close it, then start again" ;; esac
fi
# CPU seconds of the VM processes (the target's), from ps's TIME column.
vm_cpu() {
  [ "$TARGET" = mac ] && { echo null; return; }
  ps -axo pid=,comm= | grep -E "$VM_PROCS" | grep -E -- "$KEEP_VM" | awk '{print $1}' |
    while read -r p; do ps -o time= -p "$p"; done |
    awk -F'[:.]' '{ n = NF; s = $(n - 1) + 60 * $(n - 2) + (n > 3 ? 3600 * $(n - 3) : 0); t += s } END { print t + 0 }'
}

acc() { ioreg -rw0 -c AppleSmartBattery | tr ',{}' '\n\n\n' |
  sed -n 's/^"AccumulatedSystemLoad"=\([0-9]*\)$/a \1/p; s/^"SystemLoadAccumulatorCount"=\([0-9]*\)$/n \1/p' |
  sort | awk '{ v[$1] = $2 } END { print v["a"], v["n"] }'; }
spi() { ioreg -rw0 -c AppleSmartBattery | tr ',{}' '\n\n\n' | sed -n 's/^"SystemPowerIn"=\([0-9]*\)$/\1/p' | head -1; }

caffeinate -d -i -w $$ &
b0=$(brightness)
say "$TARGET: settling ${SETTLE}s, then ${SECS}s of idle power"
sleep "$SETTLE"
read -r a0 n0 <<EOF
$(acc)
EOF
c0=$(vm_cpu)
samples=$FR_TMP/samples; charged=false; t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt "$SECS" ]; do
  [ "$(battery IsCharging)" = No ] || charged=true
  echo "$(date +%s) $(spi)" >> "$samples"
  sleep 5
done
read -r a1 n1 <<EOF
$(acc)
EOF
c1=$(vm_cpu)
b1=$(brightness)
res=$(python3 - "$samples" "$a0" "$n0" "$a1" "$n1" "$charged" "$b0" "$b1" <<'PY'
import json, statistics, sys
f, a0, n0, a1, n1, charged, b0, b1 = sys.argv[1:]
mw = [int(l.split()[1]) for l in open(f) if len(l.split()) == 2]
w = [x / 1000 for x in mw]
acc = None
if n1 and n0 and int(n1) > int(n0):
    acc = round((int(a1) - int(a0)) / (int(n1) - int(n0)) / 1000, 2)
print(json.dumps({"watts_mean": round(statistics.mean(w), 2) if w else None,
                  "watts_median": round(statistics.median(w), 2) if w else None,
                  "watts_min": min(w) if w else None, "watts_max": max(w) if w else None,
                  "samples": len(w), "distinct_readings": len(set(mw)),
                  "accumulator_watts": acc, "charging_during": charged == "true",
                  "valid": charged != "true" and bool(w) and min(w) > 0,
                  "brightness_start": float(b0) if b0 != "null" else None,
                  "brightness_end": float(b1) if b1 != "null" else None}))
PY
)
rec "$TARGET" idle-power "$(python3 -c 'import json,sys
r = json.loads(sys.argv[1]); r["seconds"] = int(sys.argv[2]); r["guest_before"] = json.loads(sys.argv[3]); r["desktop"] = sys.argv[6] or None
if sys.argv[4] != "null" and sys.argv[5] != "null":   # CPU time of the VM processes, as a share of one core
    r["vm_cpu_seconds"] = round(float(sys.argv[5]) - float(sys.argv[4]), 1)
    r["vm_cpu_percent_of_core"] = round(100 * r["vm_cpu_seconds"] / int(sys.argv[2]), 1)
print(json.dumps(r))' "$res" "$SECS" "$GUEST" "$c0" "$c1" "$DESKTOP")" >/dev/null
say "$TARGET: $res"
