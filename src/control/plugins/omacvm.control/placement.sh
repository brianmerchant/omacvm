#!/bin/bash
# Put omacvm.control on the bar ahead of the Mac's own widgets (Wi-Fi, audio),
# else before the tray, else at the end of the right side. Idempotent.
set -euo pipefail

id=omacvm.control
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json

in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}

in_bar "$id" && exit 0
omarchy-shell -q shell rescanPlugins

if in_bar omacvm.wifi; then
  omarchy plugin enable "$id" --before omacvm.wifi
elif in_bar omarchy.tray; then
  omarchy plugin enable "$id" --before omarchy.tray
else
  omarchy plugin enable "$id" --section right
fi
