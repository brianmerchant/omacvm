#!/bin/bash
# Play a local video in Firefox for a few seconds in the guest's desktop session
# and print what its media log says about V4L2 / VA-API. Root in the guest.
#   firefox-run.sh file.mp4 [seconds]
#   FF_PREFS=user_pref lines for the test profile, FF_SETENV="--setenv=VAR=x ..."
set -euo pipefail
guser=${GUSER:-$(ps -o user= -p "$(pgrep -x Hyprland | head -1)")}
secs=${2:-10}
d=/tmp/cv4l2-ff; rm -rf "$d"; mkdir -p "$d/profile"
cp "$1" "$d/"; f="$d/$(basename "$1")"
printf '<!doctype html><video src="%s" autoplay muted loop></video>' "$(basename "$f")" > "$d/play.html"
cat > "$d/profile/user.js" <<P
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("media.autoplay.default", 0);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
${FF_PREFS:-}
P
chown -R "$guser:" "$d"
pkill -x firefox 2>/dev/null || true; sleep 1
systemctl --user -M "$guser@" reset-failed cv4l2-firefox 2>/dev/null || true
systemd-run --user -M "$guser@" --unit=cv4l2-firefox --collect \
  ${FF_SETENV:-} --setenv=MOZ_LOG=FFmpegVideo:5,PlatformDecoderModule:5 --setenv=MOZ_LOG_FILE="$d/moz.log" \
  /usr/bin/firefox --no-remote --profile "$d/profile" "file://$d/play.html" >/dev/null
sleep "$secs"
pkill -x firefox || true; sleep 2
cat "$d"/moz.log* 2>/dev/null | grep -iE "v4l2|vaapi|hardware|Choosing|decoder" | sed 's/^.*- //' | sort | uniq -c | sort -rn | head -30
