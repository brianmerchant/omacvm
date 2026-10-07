#!/bin/bash
# Build and install Omanotch on the Mac, and start it at login (LaunchAgent).
#   ./mac/install.sh [--prebuilt APP]   install / update
#   ./mac/uninstall.sh                  remove
# --prebuilt: that copy (OmacVM.app's, Contents/Helpers, signed with it)
# instead of building one here, which needs Xcode's Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
LABEL=ch.gillesgoetsch.omanotch
APP="$HOME/Applications/Omanotch.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ${1:-} == --prebuilt ]]; then FROM=${2:?--prebuilt APP}; else ./build.sh; FROM=build/Omanotch.app; fi
[[ -x $FROM/Contents/MacOS/omanotch ]] || { echo "no Omanotch at $FROM" >&2; exit 1; }
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x omanotch 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
ditto "$FROM" "$APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/omanotch</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/omanotch.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s+state" || true
echo "installed: $APP (log: ~/Library/Logs/omanotch.log)"
