#!/bin/bash
# Screenshot of the guest desktop (grim as the desktop user). Root in the guest.
#   shot.sh /tmp/out.png
set -euo pipefail
guser=${GUSER:-$(ps -o user= -p "$(pgrep -x Hyprland | head -1)")}
uid=$(id -u "$guser")
sig=$(ls "/run/user/$uid/hypr/" | head -1)
sudo -u "$guser" env XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-1 \
  HYPRLAND_INSTANCE_SIGNATURE="$sig" grim -s 0.5 "${1:-/tmp/shot.png}"
