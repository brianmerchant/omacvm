#!/bin/bash
# OmacVM, Mac side: Bridge (Wi-Fi, audio, media keys, display, wallpaper),
# Gestures (trackpad, scroll momentum, Cmd as Super on UTM), clipboard (VM -> Mac),
# Omanotch (the bar beside the notch, src/omanotch).
# Idempotent; `omacvm apply` runs it with what the VM's features need.
#   src/mac/install.sh [--no-bridge] [--skip-gestures | --keys-only] [--skip-clip] [--omanotch] [--force] [--quiet]
# --no-bridge leaves OmacVM Bridge out (one already installed stays, other VMs
# may use it). --skip-gestures leaves OmacVM Gestures out (likewise).
# --skip-clip leaves the clipboard helper out (only Parallels VMs use it;
# likewise kept when already installed).
# --omanotch installs Omanotch too (without it, one already installed stays as
# it is).
# --keys-only installs Gestures keys-only for every VM: macOS keeps its trackpad
# gestures, and on UTM Cmd still reaches Omarchy as Super. (Without it, each
# VM chooses for itself: gestures and scroll momentum are VM features.)
# An app whose sources and options did not change since it was installed is
# left as it is (--force rebuilds it); --quiet only reports what changed.
# macOS asks for Location Services (Bridge) and Accessibility + Input Monitoring
# (Bridge, Gestures) the first time.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
BRIDGE=1; GESTURES=1; CLIP=1; NOTCH=0; FORCE=0; QUIET=0
for a in "$@"; do
  case $a in
    --no-bridge) BRIDGE=0 ;;
    --keys-only) GESTURES=0 ;;
    --skip-gestures) GESTURES=-1 ;;
    --skip-clip) CLIP=0 ;;
    --omanotch) NOTCH=1 ;;
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    *) echo "src/mac/install.sh: unknown option $a" >&2; exit 2 ;;
  esac
done
STAMPS=~/Library/Application\ Support/omacvm/installed
mkdir -p "$HOME/.local/share/omacvm/clip" "$STAMPS"
# Up to 2.7, Gestures kept its list of VMs without a token here; nothing reads it now.
rm -f ~/Library/Application\ Support/omacvm/gestures-legacy{,.new}

# install_app NAME LAUNCHD_LABEL DIR [BUNDLE [ARGS...]]: DIR/install.sh unless
# the same sources and options are already installed and running. BUNDLE
# (OmacVMBridge.app, OmacVMGestures.app): installed from OmacVM.app's signed
# copy when the app has one built from these sources (lib/helpers.sh).
install_app() {
  local name=$1 label=$2 dir=$3 bundle=${4:-}; shift 3; (( $# )) && shift
  local sum pre="" before
  [[ -n $bundle ]] && pre=$(helpers_prebuilt "$R" "$dir" "$bundle")
  # Paths relative to src/, so another copy of the same OmacVM matches too.
  # The prebuilt copy's signature counts too: from built here to the app's
  # signed copy is a change.
  sum=$( { (cd "$R" && find "$dir" icon lib/sign.sh -type f -not -path '*/build/*' -not -name .DS_Store -print0 |
            sort -z | xargs -0 shasum); echo "args: $*"
           if [[ -n $pre ]]; then echo "prebuilt: $(shasum "$pre/Contents/_CodeSignature/CodeResources" "$pre"/Contents/MacOS/* | cut -c1-40)"; fi
         } | shasum | cut -c1-16)
  if (( ! FORCE )) && [[ $(cat "$STAMPS/$name" 2>/dev/null) == "$sum" ]] &&
     launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    (( QUIET )) || echo "$name: up to date"
    return 0
  fi
  printf '\033[1;32m==>\033[0m \033[1m%s on the Mac\033[0m%s\n' "$name" "${pre:+ (signed, from OmacVM.app)}"
  [[ -n $bundle ]] && before=$(helpers_team "$HOME/Applications/$bundle")
  if [[ -n $pre ]]; then "$R/$dir/install.sh" --prebuilt "$pre" "$@"; else "$R/$dir/install.sh" "$@"; fi
  # No stamp yet: a first install, which macOS asks permissions for. Another
  # signature (built here -> OmacVM's Developer ID) is new to macOS too: it
  # asks once more, then keeps the grants across updates.
  if [[ ! -e $STAMPS/$name ]]; then INSTALLED+=("$name")
  elif [[ -n $bundle && -n $before && $before != "$(helpers_team "$HOME/Applications/$bundle")" ]]; then
    INSTALLED+=("$name"); RESIGNED=1
  fi
  echo "$sum" > "$STAMPS/$name"
}
INSTALLED=()   # installed for the first time (an update keeps the permissions)
RESIGNED=0     # one now has another signature (the app's signed copy)
source "$R/lib/mac.sh"
source "$R/lib/app.sh"
source "$R/lib/helpers.sh"
# The token first: a Bridge starting without one makes its own, and two at
# once could end up with the file holding another token than the Bridge.
(( BRIDGE || GESTURES != -1 )) && bridge_token_ensure
(( BRIDGE )) && install_app "OmacVM Bridge" org.omacvm.bridge bridge/mac OmacVMBridge.app
# Gestures lets a VM in only when its daemon proves it knows the Bridge's
# token (made here when the Bridge is not installed).
case $GESTURES in
  1) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac OmacVMGestures.app ;;
  0) install_app "OmacVM Gestures" org.omacvm.gestures gestures/mac OmacVMGestures.app --keys-only ;;
esac
(( CLIP )) && install_app "OmacVM clipboard" org.omacvm.clip-in clipboard/mac
# Omanotch's own installer (it builds the app and starts it at login).
(( NOTCH )) && install_app "Omanotch" ch.gillesgoetsch.omanotch omanotch/mac
# The permissions macOS asks for now, once per app (they stay with later updates).
if [[ " ${INSTALLED[*]:-} " == *" OmacVM Gestures "* || " ${INSTALLED[*]:-} " == *" OmacVM Bridge "* ]]; then
  printf '\n  \033[1mmacOS asks for permissions now (once): please allow them.\033[0m\n'
  (( RESIGNED )) && printf '  (The helpers are now signed with OmacVM'"'"'s Developer ID: macOS asks once more, then keeps\n   the permissions across updates. An older "OmacVM Bridge"/"OmacVM Gestures" entry there can go: select it, -.)\n'
  printf '  In System Settings > Privacy & Security, turn on:\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Gestures "* ]] &&
    printf '    * Accessibility and Input Monitoring: OmacVM Gestures (trackpad gestures, scroll momentum, Cmd keys)\n'
  [[ " ${INSTALLED[*]} " == *" OmacVM Bridge "* ]] &&
    printf '    * Accessibility and Input Monitoring: OmacVM Bridge (media keys, brightness keys);\n      Location Services: OmacVM Bridge (Wi-Fi names); Bluetooth: OmacVM Bridge (your Bluetooth devices)\n'
  printf '  Until then those features wait; the build goes on either way.\n\n'
fi
(( QUIET )) || echo "OmacVM Mac side installed"
