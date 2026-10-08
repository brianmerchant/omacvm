#!/bin/bash
source "$(dirname "$0")/../../lib/labels.sh"
LABEL=$(omacvm_label clip-in)
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/share/omacvm/omacvm-clip-in"
echo "clipboard (VM -> Mac) removed"
