#!/bin/bash
# The VM side of the final round. vm.sh copies src/bench and tests/bench to
# /opt/omacvm-final-round and runs this as root over SSH:
#   guest.sh prepare                   BEFORE the round: full system update, the tools, vkpeak and Geekbench
#   guest.sh check MIN_WIDTH           the VM is as prepared (Mesa and the rest unchanged), wide enough
#   guest.sh info                      facts about the VM (one JSON line)
#   guest.sh viewport                  Chrome's page size in full screen (one JSON line)
#   guest.sh throughput|vkpeak|geekbench|vkmark|glmark2|browser RUNS
#   guest.sh cleanup [--packages]      AFTER the round: remove our files (and the packages prepare added)
# Only in benchmark VMs (vm.sh checks the name). The tests run as the desktop
# user (uid 1000) in its Hyprland session. Each prints JSON lines on stdout;
# vm.sh adds the target and the Mac's facts. Google Chrome must already be
# there (pacman/AUR, or install-chrome.sh in a benchmark VM you made
# yourself): this script never installs it.
set -uo pipefail
B=$(cd "$(dirname "$0")/../../.." && pwd)   # the copy's root: src/bench, tests/bench
S=$B/state                                   # what prepare found, kept between runs
U=$(id -nu 1000)
CMD=${1:-}; RUNS=${2:-3}
CACHE=/home/$U/.cache/omacvm-bench
PKGS="glmark2 vkmark vulkan-tools clinfo opencl-mesa mesa-utils git cmake base-devel"
CPU_DEV='llvmpipe|lavapipe|swiftshader|softpipe'
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
pkgver() { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }
# What the round depends on; prepare keeps it, check compares (Mesa pinned).
versions() {
  printf 'mesa=%s\nomacvm-mesa=%s\nglmark2=%s\nvkmark=%s\nvulkan-virtio=%s\nchrome=%s\nlinux=%s\n' \
    "$(pkgver mesa)" "$(cat /opt/omacvm-mesa/omacvm-mesa-version 2>/dev/null)" "$(pkgver glmark2)" "$(pkgver vkmark)" \
    "$(pkgver vulkan-virtio)" "$(chrome_version)" "$(uname -r)"
}
widths() { as_user hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; print(" ".join(str(m["width"]) for m in json.load(sys.stdin)))' 2>/dev/null; }

case $CMD in
prepare)
  mkdir -p "$S"
  [[ -f $S/packages-before ]] || pacman -Qq > "$S/packages-before"
  # A full update now, not in the round: -S on an old database can 404, and
  # -Sy alone would be a partial upgrade. After this, nothing changes until cleanup.
  # Omarchy 4.0.3's pacman hook refuses a direct upgrade unless this is set
  # (it wants `omarchy update`); a benchmark VM takes the plain full update.
  export OMARCHY_ALLOW_DIRECT_PACMAN=1
  pacman -Syu --noconfirm >/dev/null || { echo "pacman -Syu failed" >&2; exit 1; }
  # shellcheck disable=SC2086
  pacman -S --needed --noconfirm $PKGS >/dev/null || { echo "pacman -S $PKGS failed" >&2; exit 1; }
  pacman -Qq | comm -13 "$S/packages-before" - > "$S/installed-packages"
  [[ -n $(chrome_version) ]] || { echo "Google Chrome is missing in this VM" >&2; exit 1; }
  # vkpeak and Geekbench into the user's cache, now: no build or download (or heat) in the round.
  as_user bash "$B/tests/bench/vkpeak/vkpeak.sh" --runs 0 >/dev/null 2>&1
  as_user bash "$B/src/bench/bench.sh" --runs 0 --only none /dev/null >/dev/null 2>&1
  versions > "$S/prepared"
  date -u +%FT%TZ > "$S/prepared-at"
  if [[ ! -d /usr/lib/modules/$(uname -r) ]]; then
    echo "the kernel was updated: reboot the VM, then run prepare again" >&2; exit 3
  fi
  echo "prepared: $(tr '\n' ' ' < "$S/prepared")" >&2 ;;
check)
  min=${2:-3000}; problems=()
  if [[ ! -f $S/prepared ]]; then problems+=("not prepared: run vm.sh ... --prepare before the round")
  else
    d=$(diff <(cat "$S/prepared") <(versions) | sed -n 's/^> //p' | tr '\n' ' ')
    [[ -z $d ]] || problems+=("changed since prepare (the round keeps Mesa and the rest fixed): $d")
  fi
  [[ -d /usr/lib/modules/$(uname -r) ]] || problems+=("the running kernel's modules are gone (updated): reboot")
  [[ -n $(chrome_version) ]] || problems+=("Google Chrome is missing")
  w=$(widths)
  [[ -n $w ]] || problems+=("no Hyprland session for uid 1000 (log in on the VM's screen)")
  for x in $w; do (( x >= min )) || problems+=("a monitor is $x px wide, the round needs $min (the VM in full screen on the built-in display)"); done
  printf '%s\n' "${problems[@]}" | python3 -c 'import json,sys; p=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps({"ok": not p, "problems": p}))'
  (( ${#problems[@]} == 0 )) ;;
info)
  mode=$(as_user hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys
m=json.load(sys.stdin)
print("; ".join("%s %dx%d@%.0f scale %s" % (x["name"], x["width"], x["height"], x["refreshRate"], x["scale"]) for x in m))' 2>/dev/null)
  gl=$(as_user eglinfo -B 2>/dev/null | sed -n 's/.*OpenGL ES profile renderer: //p' | head -1)
  vk=$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceName *= *//p' | tr '\n' ';' | sed 's/;$//')
  python3 - "$mode" "$gl" "$vk" "$(chrome_version)" "$(widths)" "$(cat "$S/prepared-at" 2>/dev/null)" <<'EOF'
import json, os, subprocess, sys
def q(*a):
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return ""
print(json.dumps({"kernel": os.uname().release, "cpus": os.cpu_count(),
                  "mem_gb": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1),
                  "monitors": sys.argv[1], "monitor_widths": [int(x) for x in sys.argv[5].split()],
                  "gl_renderer": sys.argv[2], "vulkan_devices": sys.argv[3] or None,
                  "chrome": sys.argv[4], "mesa": q("pacman", "-Q", "mesa"), "glmark2": q("pacman", "-Q", "glmark2"),
                  "vkmark": q("pacman", "-Q", "vkmark"),
                  "omacvm_mesa": open("/opt/omacvm-mesa/omacvm-mesa-version").read().strip()
                                 if os.path.exists("/opt/omacvm-mesa/omacvm-mesa-version") else None,
                  "prepared_at": sys.argv[6] or None,
                  "load": open("/proc/loadavg").read().split()[:3]}))
EOF
  ;;
viewport)
  as_user python3 "$B/tests/bench/gpu-throughput/run.py" --viewport-only ;;
throughput)   # each session: the timer method, then the wall method (summarize picks one per row)
  for ((i = 1; i <= RUNS; i++)); do
    as_user python3 "$B/tests/bench/gpu-throughput/run.py" --method timer
    as_user python3 "$B/tests/bench/gpu-throughput/run.py" --method wall
  done ;;
vkpeak)
  as_user bash "$B/tests/bench/vkpeak/vkpeak.sh" --runs "$RUNS" 2>/dev/null ;;
geekbench)   # Geekbench GPU, Vulkan and OpenCL, only on a real GPU device (bench.sh checks)
  # OpenCL is rusticl on zink, so on Vulkan: a GPU only where Vulkan has one
  # (OmacVM.app with Venus); on lavapipe it is a CPU device and bench.sh says so.
  out=$(mktemp); chmod 666 "$out"
  as_user env RUSTICL_ENABLE="${RUSTICL_ENABLE:-zink}" bash "$B/src/bench/bench.sh" --runs "$RUNS" --only gpu "$out" >/dev/null 2>&1
  cat "$out"; rm -f "$out" ;;
vkmark)
  v=$(pkgver vkmark)
  [[ -n $v ]] || { echo '{"error":"vkmark missing (prepare installs it)"}'; exit 0; }
  types=$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceType *= *//p' | sort -u | tr '\n' ' ')
  [[ -n $types ]] || { echo "{\"not_available\":\"no Vulkan device\",\"vkmark\":\"$v\"}"; exit 0; }
  [[ $types == "PHYSICAL_DEVICE_TYPE_CPU " ]] && { echo "{\"not_available\":\"CPU Vulkan only, no GPU\",\"vkmark\":\"$v\"}"; exit 0; }
  dev=()   # the first device that is not a CPU one, where vkmark can be told
  if vkmark --help 2>&1 | grep -q -- --use-device; then
    uuid=$(vulkaninfo --summary 2>/dev/null | awk '/deviceType *=/ { t = $NF } /deviceUUID *=/ && t != "PHYSICAL_DEVICE_TYPE_CPU" && u == "" { u = $NF } END { print u }')
    [[ -n $uuid ]] && dev=(--use-device "$uuid")
  fi
  for ((i = 1; i <= RUNS; i++)); do
    raw=$(as_user vkmark --fullscreen "${dev[@]}" 2>&1)
    s=$(sed -n 's/.*vkmark Score: *\([0-9]*\).*/\1/p' <<<"$raw" | tail -1)
    name=$(sed -n 's/^ *Device Name: *//p' <<<"$raw" | head -1)
    if grep -Eqi "$CPU_DEV" <<<"$name"; then echo "{\"not_available\":\"vkmark ran on a CPU device (${name//\"/})\",\"vkmark\":\"$v\"}"; exit 0; fi
    echo "{\"run\":$i,\"value\":${s:-null},\"device\":\"${name//\"/}\",\"vkmark\":\"$v\"}"
  done ;;
glmark2)
  v=$(pkgver glmark2)
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
cleanup)
  pk=$(cat "$S/installed-packages" 2>/dev/null | tr '\n' ' ')
  rm -rf "$CACHE" "$B"
  if [[ ${2:-} == --packages && -n ${pk// /} ]]; then
    # shellcheck disable=SC2086
    pacman -Rns --noconfirm $pk >/dev/null && echo "removed: $pk" >&2
  elif [[ -n ${pk// /} ]]; then
    echo "prepare installed: $pk (remove with: pacman -Rns $pk)" >&2
  fi
  echo "removed $B and $CACHE" >&2 ;;
*) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
