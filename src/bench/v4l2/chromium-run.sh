#!/bin/bash
# (Re)start Chromium in the guest's desktop session, as the desktop user, with
# DevTools on 127.0.0.1:9222 and media/V4L2 logging to the user journal.
# Run as root in the guest.
#   FEAT=AcceleratedVideoDecoder,...   features to enable (default: none)
#   DISABLE=...                        features to disable
#   EXTRA='--flag ...'                 more Chromium flags
#   BROWSER=chromium                   binary (chromium, google-chrome-stable, brave)
#   GUSER=<user>                       desktop user (default: the one running Hyprland)
#   QUIET=1                            no media logging (it costs CPU: for measurements)
set -euo pipefail

guser=${GUSER:-$(ps -o user= -p "$(pgrep -x Hyprland | head -1)")}
browser=${BROWSER:-chromium}
prof=/tmp/cv4l2-profile

pkill -x "$(basename "$browser")" 2>/dev/null || true
pkill -f -- "--user-data-dir=$prof" 2>/dev/null || true
sleep 2
systemctl --user -M "$guser@" reset-failed cv4l2-browser 2>/dev/null || true
rm -rf "$prof"

args=(--user-data-dir="$prof" --remote-debugging-port=9222 --no-first-run
      --no-default-browser-check --password-store=basic --autoplay-policy=no-user-gesture-required
      --ozone-platform=wayland)
[ -n "${QUIET:-}" ] || args+=(--enable-logging=stderr
      --vmodule='*/media/gpu/*=4,*/media/gpu/v4l2/*=4,*/media/gpu/chromeos/*=4,*/mojo/services/*=3')
[ -n "${FEAT:-}" ] && args+=(--enable-features="$FEAT")
[ -n "${DISABLE:-}" ] && args+=(--disable-features="$DISABLE")
# shellcheck disable=SC2206
[ -n "${EXTRA:-}" ] && args+=($EXTRA)

systemd-run --user -M "$guser@" --unit=cv4l2-browser --collect \
  "$(command -v "$browser")" "${args[@]}" about:blank >/dev/null

for _ in $(seq 1 60); do
  curl -s 127.0.0.1:9222/json/version >/dev/null && { echo "browser up: $browser ${args[*]}"; exit 0; }
  sleep 1
done
echo "browser did not come up" >&2
journalctl --user -M "$guser@" -u cv4l2-browser --no-pager | tail -30 >&2
exit 1
