#!/bin/bash
# Stop and remove Omanotch from the Mac.
set -euo pipefail
source "$(dirname "$0")/../../lib/labels.sh"
LABEL=$(omacvm_label omanotch)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -x omanotch 2>/dev/null || true
rm -rf "$HOME/Applications/Omanotch.app"
echo "removed (the log ~/Library/Logs/omanotch.log is kept)"
