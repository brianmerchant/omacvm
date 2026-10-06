#!/bin/bash
# omacvm-vdecd, Chromium's decoder service. Root, in the VM:
#   vdecd.sh build OUT  the daemon, built against the VM's FFmpeg, libva and
#                       Mesa (build log: LOG)
#   vdecd.sh hook       after a pacman update of those (95-omacvm-vdecd.hook):
#                       built again when a library it links to is gone (a new
#                       FFmpeg: libavcodec.so.N), started again when it is down
#                       (a fixed Mesa: the GPU may work now). A running daemon
#                       is left alone: it may have a video open.
#   vdecd.sh why        one line: why it is not running
# Tests: src/tests/vdecd-down.sh (OMACVM_VDECD_BIN, OMACVM_VDECD_UNIT and
# OMACVM_VDECD_LOG point elsewhere there).
set -uo pipefail
cd "$(dirname "$0")" || exit 1
BIN=${OMACVM_VDECD_BIN:-/usr/local/bin/omacvm-vdecd}
UNIT=${OMACVM_VDECD_UNIT:-/etc/systemd/system/omacvm-vdecd.service}
LOG=${OMACVM_VDECD_LOG:-/var/lib/omacvm/vdec-build.log}

build() {   # OUT
  local pkgs="libva libva-drm egl glesv2 gbm libdrm libavcodec libavutil libsystemd"
  # shellcheck disable=SC2046,SC2086
  cc -O2 -Wall -Imodule -o "$1" omacvm-vdecd.c $(pkg-config --cflags --libs $pkgs) >> "$LOG" 2>&1
}

# The first library the daemon links to that is not there any more.
missing() {
  ldd "$BIN" 2>/dev/null | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p' | head -1
}

case ${1:-} in
build)
  build "${2:?usage: vdecd.sh build OUT}" ;;
hook)
  [[ -f $UNIT && -e $BIN ]] || exit 0
  m=$(missing)
  if [[ -n $m ]]; then
    T=$(mktemp -d) || exit 0
    if build "$T/omacvm-vdecd"; then
      install -m755 "$T/omacvm-vdecd" "$BIN"
      echo "omacvm-vdecd: built again ($m is gone)"
    else
      echo "omacvm-vdecd: does not build against the new libraries (log: $LOG): omacvm apply"
    fi
    rm -rf "$T"
  fi
  # (No systemd to ask in a chroot: nothing to start.)
  systemctl is-active -q omacvm-vdecd 2>/dev/null || systemctl restart --no-block omacvm-vdecd.service 2>/dev/null
  exit 0 ;;
why)
  m=$(missing)
  if [[ -n $m ]]; then echo "built for an FFmpeg that is gone ($m missing): omacvm apply"; exit 0; fi
  sub=$(systemctl show -p SubState --value omacvm-vdecd 2>/dev/null)
  res=$(systemctl show -p Result --value omacvm-vdecd 2>/dev/null)
  # Its own last word this boot ("ready" is not a reason).
  last=$(journalctl -b -u omacvm-vdecd -o cat --no-pager -n 50 2>/dev/null |
    sed -n 's/^vdecd: //p' | grep -v '^ready' | tail -1)
  case $res in
    watchdog) why="it stopped answering (killed by the watchdog)" ;;
    signal|core-dump) why="it crashed (journalctl -u omacvm-vdecd)" ;;
    start-limit-hit) why="it failed too often: systemctl restart omacvm-vdecd" ;;
    *) why=${last:-"not running (journalctl -u omacvm-vdecd)"} ;;
  esac
  [[ $sub == auto-restart && $why != *"trying again"* ]] && why="$why; starts again by itself"
  echo "$why" ;;
*)
  echo "usage: vdecd.sh build OUT | hook | why" >&2; exit 2 ;;
esac
