#!/bin/bash
# omacvm fullscreen: OmacVM.app's Full screen mode, shared with its Settings.
#   omacvm fullscreen                    show the setting
#   omacvm fullscreen native|fullpanel   change it for the next VM start
#   omacvm fullscreen --configure        choose Native or Full Panel (Experimental)
#   --json   the setting as JSON (after a change: "changed": true)
# Native is the default. This app-wide preference applies to OmacVM.app only.
# Guest components install automatically through normal build/apply/update.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/app.sh"
SET=""; JSON=0; CONFIGURE=0; CHANGED=false
usage() { echo "omacvm fullscreen: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    native|fullpanel) [[ -z $SET ]] || usage "one setting"; SET=$1; shift ;;
    --json) JSON=1; shift ;;
    --configure) CONFIGURE=1; shift ;;
    -h|--help) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) usage "unknown option $1 (see --help)" ;;
  esac
done
if (( CONFIGURE )); then
  [[ -z $SET ]] && (( ! JSON )) || usage "--configure goes without a setting or --json"
  source "$R/src/lib/setup.sh"
  source "$R/src/lib/ui.sh"
  { : < "$TTY"; } 2>/dev/null || usage "--configure needs a terminal (or pass native|fullpanel)"
  trap ui_restore EXIT
  pick=0; [[ $(app_fullscreen_choice) == fullpanel ]] && pick=1
  ui_select pick "Full screen mode (OmacVM.app Settings, all app VMs)" "$pick" \
    "Native|default · macOS full screen" \
    "Full Panel (Experimental)|use the physical area beside the MacBook camera housing"
  (( pick )) && SET=fullpanel || SET=native
fi
if [[ -n $SET && $SET != "$(app_fullscreen_choice)" ]]; then
  app_fullscreen_set "$SET" || { echo "omacvm fullscreen: could not save the app's Full screen mode" >&2; exit 1; }
  CHANGED=true
fi
mode=$(app_fullscreen_choice)
if (( JSON )); then
  printf '{"fullscreen_mode":"%s","changed":%s,"next_start":true}\n' "$mode" "$CHANGED"
else
  printf 'Full screen mode: %s (OmacVM.app Settings; from the next VM start)\n' "$(app_fullscreen_title "$mode")"
fi
