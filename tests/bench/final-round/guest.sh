#!/bin/bash
# The VM side of the final round. vm.sh copies src/bench and tests/bench to
# /opt/omacvm-final-round and runs this as root over SSH:
#   guest.sh info                      facts about the VM (one JSON line)
#   guest.sh prepare                   glmark2, vulkan-tools and vkpeak's build tools, with pacman
#   guest.sh throughput|vkpeak|glmark2|browser RUNS
# The tests run as the desktop user (uid 1000) in its Hyprland session. Each
# prints JSON lines on stdout; vm.sh adds the target and the Mac's facts.
# Google Chrome must already be there (pacman/AUR, or install-chrome.sh in a
# benchmark VM you made yourself): this script never installs it.
set -uo pipefail
B=$(cd "$(dirname "$0")/../../.." && pwd)   # the copy's root: src/bench, tests/bench
U=$(id -nu 1000)
CMD=${1:-}; RUNS=${2:-3}
as_user() {
  local sig
  sig=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
  sudo -u "$U" env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE="$sig" \
    HOME="/home/$U" OMACVM_BENCH_SRC="$B/src/bench" "$@"
}
chrome_version() {
  local c
  for c in /opt/google/chrome/google-chrome google-chrome-stable; do
    command -v "$c" >/dev/null && { "$c" --version 2>/dev/null; return; }
  done
}

case $CMD in
info)
  mode=$(as_user hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys
m=json.load(sys.stdin)
print("; ".join("%s %dx%d@%.0f scale %s" % (x["name"], x["width"], x["height"], x["refreshRate"], x["scale"]) for x in m))' 2>/dev/null)
  gl=$(as_user eglinfo -B 2>/dev/null | sed -n 's/.*OpenGL ES profile renderer: //p' | head -1)
  vk=$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName *= *//p' | head -1)
  python3 - "$mode" "$gl" "$vk" "$(chrome_version)" <<'EOF'
import json, os, subprocess, sys
def q(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return ""
print(json.dumps({"kernel": os.uname().release, "cpus": os.cpu_count(),
                  "mem_gb": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1),
                  "monitors": sys.argv[1], "gl_renderer": sys.argv[2], "vulkan_device": sys.argv[3] or None,
                  "chrome": sys.argv[4], "mesa": q("pacman", "-Q", "mesa"), "glmark2": q("pacman", "-Q", "glmark2"),
                  "omacvm_mesa": open("/opt/omacvm-mesa/omacvm-mesa-version").read().strip()
                                 if os.path.exists("/opt/omacvm-mesa/omacvm-mesa-version") else None,
                  "load": open("/proc/loadavg").read().split()[:3]}))
EOF
  ;;
prepare)
  pacman -S --needed --noconfirm glmark2 vulkan-tools git cmake base-devel mesa-utils >/dev/null || exit 1
  [[ -n $(chrome_version) ]] || { echo "Google Chrome is missing in this VM" >&2; exit 1; }
  as_user bash "$B/tests/bench/vkpeak/vkpeak.sh" --runs 0 >/dev/null 2>&1   # builds vkpeak once (or says why not)
  ;;
throughput)
  for ((i = 1; i <= RUNS; i++)); do as_user python3 "$B/tests/bench/gpu-throughput/run.py"; done ;;
vkpeak)
  as_user bash "$B/tests/bench/vkpeak/vkpeak.sh" --runs "$RUNS" 2>/dev/null ;;
glmark2)
  v=$(pacman -Q glmark2 2>/dev/null | awk '{print $2}')
  [[ $v == "$GLMARK2_VERSION"* ]] || { echo "{\"error\":\"glmark2 ${v:-missing}, the round uses ${GLMARK2_VERSION:-?}\"}"; exit 0; }
  for ((i = 1; i <= RUNS; i++)); do
    s=$(as_user glmark2-es2-wayland --fullscreen 2>&1 | sed -n 's/.*glmark2 Score: *\([0-9]*\).*/\1/p')
    echo "{\"run\":$i,\"value\":${s:-null},\"glmark2\":\"$v\"}"
  done ;;
browser)   # Basemark Web 3.0 and WebGL Aquarium 30k, bench.sh's way (full-screen Chrome)
  out=$(mktemp)
  chmod 666 "$out"
  as_user bash "$B/src/bench/bench.sh" --runs "$RUNS" --only aquarium,basemark "$out" >/dev/null 2>&1
  cat "$out"; rm -f "$out" ;;
*) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
