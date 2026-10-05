#!/bin/bash
# fractional-scale.sh: Omarchy's display scales in an OmacVM.app VM, one after the other, the way
# its scale menu sets them (omarchy-hyprland-monitor-scaling). For each scale it checks that
#   * the output keeps its mode (the size of the Mac window) and gets the clean scale,
#   * the display sync sent at most one rule and never held the output (no loop),
#   * QEMU's log has no refused GPU memory and no lost GPU context since the change,
# and prints one JSON line per scale (with --frames also the frame times of a full-screen
# Chromium page, tests/graphics/pacing/pacing.html, for SECS seconds).
#
#   tests/graphics/fractional-scale.sh --port 52431 [--user gilles] [--key ~/.ssh/omacvm]
#       [--qemu-log "<VM folder>/logs/qemu.log"] [--scales "1 1.25 1.5 1.6 1.75 2"]
#       [--frames SECS] [--hz 60]
#
# Exit 1 when a scale failed a check. Frame times are only comparable with the benchmark lock
# held and the other test VMs paused (tests/graphics/pacing/README.md).
set -u
port="" user=gilles key=$HOME/.ssh/omacvm qlog="" scales="1 1.25 1.5 1.6 1.75 2" frames=0 hz=60
while (($#)); do
  case $1 in
    --port) port=$2; shift 2 ;;
    --user) user=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --qemu-log) qlog=$2; shift 2 ;;
    --scales) scales=$2; shift 2 ;;
    --frames) frames=$2; shift 2 ;;
    --hz) hz=$2; shift 2 ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
  esac
done
[[ -n $port ]] || { sed -n '2,15p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
ssh_vm() {
  ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}
# A command in the desktop user's Hyprland session.
as_user() {
  ssh_vm "uid=\$(id -u $user); sig=\$(ls -t /run/user/\$uid/hypr | head -1); cd /tmp; sudo -u $user env \
XDG_RUNTIME_DIR=/run/user/\$uid WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$sig $*"
}
monitor() {
  as_user hyprctl -j monitors | python3 -c '
import json, sys
m = next(m for m in json.load(sys.stdin) if m["name"] == "Virtual-1")
print(m["width"], m["height"], m["scale"])'
}
clean_scale() {   # what Omarchy's own script picks: the next scale up that keeps whole pixels
  awk -v s="$1" -v w="$2" -v h="$3" 'function gcd(a, b, t) { while (b) { t = a % b; a = b; b = t } return a }
    BEGIN { g = gcd(w * 120, h * 120); k = int(s * 120 + 0.5); if (k > g) k = g; while (g % k) k++; printf "%g\n", k / 120 }'
}
state=/run/user/$(ssh_vm id -u "$user")/omacvm/display-sync

if ((frames)); then
  ssh_vm "mkdir -p /tmp/omacvm-pacing" &&
    scp -q -i "$key" -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "$here/pacing/pacing.html" "$here/pacing/srv.py" "$here/pacing/stats.py" root@127.0.0.1:/tmp/omacvm-pacing/ &&
    ssh_vm "chmod -R a+rX /tmp/omacvm-pacing"
  as_user "setsid -f python3 /tmp/omacvm-pacing/srv.py >/dev/null 2>&1 </dev/null"
  trap 'as_user "pkill -f /tmp/omacvm-pacing/srv.py" >/dev/null 2>&1' EXIT INT TERM
fi

read -r w0 h0 s0 < <(monitor) || { echo "no Virtual-1 in Hyprland" >&2; exit 1; }
fail=0
for s in $scales; do
  t0=$(ssh_vm date +%s.%N)
  qlines=$([[ -f $qlog ]] && wc -l < "$qlog" || echo 0)
  held0=$(ssh_vm "cat $state/held 2>/dev/null | wc -l")
  as_user omarchy-hyprland-monitor-scaling "$s" >/dev/null 2>&1
  sleep 5
  read -r w h shown < <(monitor)
  want=$(clean_scale "$s" "$w0" "$h0")
  applies=$(ssh_vm "awk -v t=$t0 '\$1 >= t' $state/Virtual-1.history 2>/dev/null | wc -l")
  held=$(( $(ssh_vm "cat $state/held 2>/dev/null | wc -l") - held0 ))
  gpu=""
  [[ -f $qlog ]] && gpu=$(tail -n +"$((qlines + 1))" "$qlog" | grep -E 'budget of [0-9]+ MB reached|is lost|context error reported' | head -1)
  peak=$([[ -f $qlog ]] && grep -o 'guest GPU memory in use: [0-9]* MB' "$qlog" | tail -1 | grep -o '[0-9]*')
  why=()
  [[ $w == "$w0" && $h == "$h0" ]] || why+=("mode $w x $h, was $w0 x $h0")
  awk -v a="$shown" -v b="$want" 'BEGIN { exit !(a - b < 0.001 && b - a < 0.001) }' || why+=("scale $shown, want $want")
  ((applies <= 1)) || why+=("display sync sent $applies rules")
  ((held == 0)) || why+=("display sync held the output")
  [[ -z $gpu ]] || why+=("GPU: $gpu")
  ft="null"
  if ((frames)); then
    as_user "rm -f /tmp/pacing-stats.json; setsid -f chromium --ozone-platform=wayland --kiosk --no-first-run \
--user-data-dir=/tmp/omacvm-pacing/profile 'http://127.0.0.1:8765/pacing.html?secs=$frames&hz=$hz' >/dev/null 2>&1 </dev/null"
    for _ in $(seq $((frames + 30))); do ssh_vm test -s /tmp/pacing-stats.json && break; sleep 1; done
    ft=$(ssh_vm "python3 /tmp/omacvm-pacing/stats.py /tmp/pacing-stats.json $(awk -v h="$hz" 'BEGIN { print 1000 / h }')" 2>/dev/null || echo null)
    as_user "pkill -f -- '--user-data-dir=/tmp/omacvm-pacing/profile'" >/dev/null 2>&1
    sleep 2
  fi
  ok=true; ((${#why[@]})) && { ok=false; fail=1; }
  printf '{"scale": "%s", "ok": %s, "mode": "%sx%s", "shown_scale": %s, "logical": "%sx%s", "applies": %s, "held": %s, "gpu_peak_mb": %s, "frames": %s, "why": "%s"}\n' \
    "$s" "$ok" "$w" "$h" "$shown" "$(awk -v a="$w" -v s="$shown" 'BEGIN { printf "%d", a / s + 0.5 }')" \
    "$(awk -v a="$h" -v s="$shown" 'BEGIN { printf "%d", a / s + 0.5 }')" "$applies" "$held" "${peak:-null}" "$ft" \
    "$(IFS=';'; echo "${why[*]:-}")"
done
exit $fail
