#!/bin/bash
# Guest-only wiring, called by the supported OmacVM.app guest installer.
# FullPanel is a boot setting, not a separate features.tsv switch. Provision
# its inactive plugin/hook in native mode so selecting it needs no guest setup.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: fullpanel-install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
[[ -d $H && $H != / ]] || { echo "FullPanel: invalid desktop home" >&2; exit 1; }
# Leave a detectable failure/incomplete marker, including after interruption.
# Only a fully successful supported install clears it. No bar is selected here.
S=$H/.local/state/omacvm
[[ ! -L $S && ! -L $S/fullpanel-install-failed ]] || { echo "FullPanel: unmanaged state symlink; left unchanged" >&2; exit 1; }
install -d -o "$U" -g "$U" "$S"
printf 'FullPanel guest installation did not complete; run OmacVM apply/update again.\n' > "$S/fullpanel-install-failed"
chown "$U:$U" "$S/fullpanel-install-failed"
install -Dm755 fullpanel.py /usr/local/bin/omacvm-fullpanel
install -Dm755 fullpanel-bar.py /usr/local/lib/omacvm/fullpanel-bar.py
runuser -u "$U" -- env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
  bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap; exec /usr/local/bin/omacvm-fullpanel install'
# Publish the hook only after a validated plugin is available. Do not touch
# Omanotch's Lua, plugins, unit files, enablement or pending-install record.
install -d -o "$U" -g "$U" "$H/.config/hypr"
[[ ! -L $H/.config/hypr/omacvm_fullpanel.lua && ! -L $H/.config/hypr/.omacvm_fullpanel.lua.new ]] || {
  echo "FullPanel: unmanaged hook symlink; left unchanged" >&2; exit 1
}
if ! cmp -s omacvm_fullpanel.lua "$H/.config/hypr/omacvm_fullpanel.lua"; then
  install -o "$U" -g "$U" -m644 omacvm_fullpanel.lua "$H/.config/hypr/.omacvm_fullpanel.lua.new"
  mv -f "$H/.config/hypr/.omacvm_fullpanel.lua.new" "$H/.config/hypr/omacvm_fullpanel.lua"
fi
B=$H/.config/hypr/hyprland.lua
[[ -f $B && ! -L $B ]] || { echo "FullPanel: unsupported Hyprland config; left unchanged" >&2; exit 1; }
grep -qxF 'require("hypr.omacvm_fullpanel")' "$B" || {
  printf '\n-- OmacVM: select the FullPanel/native bar before the shell starts.\nrequire("hypr.omacvm_fullpanel")\n' >> "$B"
  chown "$U:$U" "$B"
}
rm -f "$S/fullpanel-install-failed"
