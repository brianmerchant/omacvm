# OmacVM's Mac helpers (Bridge, Gestures) prebuilt in OmacVM.app (sourced by
# src/mac/install.sh; bash 3.2). The app carries them built from its own
# copy of src/ and signed with OmacVM's Developer ID, so macOS keeps their
# Accessibility and Input Monitoring grants across updates and nothing is
# compiled on the user's Mac. A copy is used only when it was built from the
# same sources as the OmacVM that installs it; otherwise (a source checkout
# without the app, or another version) the helper is built here as before.
#   helpers_src_sum SRC DIR      a short hash of DIR's sources under SRC (with
#                                the icon and the signing script it uses)
#   helpers_dirs SRC             the Helpers folders to look in, best first:
#                                OMACVM_HELPERS, the app SRC is inside, the
#                                installed OmacVM.app
#   helpers_prebuilt SRC DIR APP  the prebuilt APP (OmacVMBridge.app ...) for
#                                SRC's DIR, or nothing

helpers_src_sum() {   # SRC DIR
  ( cd "$1" && find "$2" icon lib/sign.sh -type f -not -path '*/build/*' -not -name .DS_Store -print0 |
      sort -z | xargs -0 shasum ) | shasum | cut -c1-16
}

helpers_dirs() {   # SRC
  local d c
  [[ -n ${OMACVM_HELPERS:-} ]] && echo "$OMACVM_HELPERS"
  # SRC = .../Contents/Resources/omacvm/src inside an app.
  c=$(cd "$1/../../.." 2>/dev/null && pwd) && [[ ${c##*/} == Contents && -d $c/Helpers ]] && echo "$c/Helpers"
  if declare -F app_bundle >/dev/null && d=$(app_bundle 2>/dev/null) && [[ -d $d/Contents/Helpers ]]; then
    echo "$d/Contents/Helpers"
  fi
  return 0
}

helpers_prebuilt() {   # SRC DIR APP
  local h want
  want=$(helpers_src_sum "$1" "$2")
  while IFS= read -r h; do
    [[ -n $h && -d $h/$3 && -d $h/../Resources/omacvm/src/$2 ]] || continue
    [[ $(helpers_src_sum "$h/../Resources/omacvm/src" "$2") == "$want" ]] || continue
    codesign --verify --strict "$h/$3" >/dev/null 2>&1 || continue
    (cd "$h" && echo "$PWD/$3")
    return 0
  done < <(helpers_dirs "$1")
  return 0
}

helpers_team() {   # APP: its signing team, "adhoc", or nothing (not there)
  [[ -d $1 ]] || return 0
  local t
  t=$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ -z $t || $t == "not set" ]] && t=adhoc
  echo "$t"
}
