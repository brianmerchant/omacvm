#!/bin/bash
# Fusion's guest install: the first Hyprland build must run from the source
# tree, whose build-hyprland.sh finds guest/pkg-add next to it. The root-owned
# copy in /usr/local/lib/omacvm/fusion is only for the pacman hook (--hook,
# no pacman calls). 3.0.0-3.0.3 ran the copy, and every new Fusion VM stopped
# at "failed during: VMware Fusion".
set -euo pipefail
cd "$(dirname "$0")/../.."
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
f=src/fusion/guest/install.sh
check "first build runs from the source tree" "grep -qx '\"\$here/build-hyprland.sh\" \"\$U\"' $f"
check "no build from the installed copy without --hook" "! grep -E '^\s*\"\\\$L/build-hyprland.sh\"' $f | grep -vq -- '--hook'"
check "build-hyprland.sh still reaches pkg-add relative to itself" "grep -q '\$here/../../guest/pkg-add' src/fusion/guest/build-hyprland.sh && [[ -x src/guest/pkg-add ]]"
check "the hook calls the installed copy with --hook" "grep -q 'Exec = /usr/local/lib/omacvm/fusion/build-hyprland.sh --hook' $f"
# The hook path never calls pkg-add.
check "--hook skips pkg-add" "grep -q 'if (( ! HOOK )); then \"\$here/../../guest/pkg-add\"' src/fusion/guest/build-hyprland.sh"
# Every guest script that uses "$here/" sets it (build-open-vm-tools.sh did not:
# "here: unbound variable" right after the Hyprland build, 3.0.0-3.0.3).
for g in src/fusion/guest/*.sh; do
  if grep -q '"\$here/' "$g"; then check "$(basename "$g") sets \$here" "grep -qE '^here=' $g"; fi
done

# Display scale (monitors.lua): the block of install.sh that writes it, run on
# a scratch home. A new VM starts at the Mac display's scale (SCALE, from
# mac-display --scale), 2 without it; the scale chosen in Omarchy's menu stays.
# Up to 3.0.4 it was 2 only from 3000 px wide: a MacBook Air (2940 px) got 1.
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
sed -n '/^M=\$H\/.config\/hypr\/monitors.lua/,/^if cmp -s/p' $f > "$t/block.sh"
check "monitors.lua block found" "grep -q '^if cmp -s' $t/block.sh"
omarchy_lua() {   # Omarchy's own monitors.lua, scale "auto" or a number
  printf -- '-- See https://wiki.hypr.land/Configuring/Basics/Monitors/\nlocal omarchy_monitor_scale = %s\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })\nlocal omarchy_gdk_scale = 2\nhl.env("GDK_SCALE", tostring(omarchy_gdk_scale))\n' "$1"
}
run_block() {   # MODE [SCALE]: run the block on $t/home, print "scale gdk mode"
  # shellcheck disable=SC2034  # read by block.sh
  ( set -euo pipefail; H=$t/home U=nobody MODE=$1 DSCALE=${2:-}
    chown() { :; }
    source "$t/block.sh" )
  printf '%s %s %s\n' "$(sed -n 's/^local omarchy_monitor_scale = //p' "$t/home/.config/hypr/monitors.lua")" \
    "$(sed -n 's/^local omarchy_gdk_scale = //p' "$t/home/.config/hypr/monitors.lua")" \
    "$(sed -n 's/^hl.monitor({ output = "Virtual-1", mode = "\([^"]*\)".*/\1/p' "$t/home/.config/hypr/monitors.lua")"
}
fresh() { rm -rf "${t:?}/home"; mkdir -p "$t/home/.config/hypr"; [[ -z ${1:-} ]] || omarchy_lua "$1" > "$t/home/.config/hypr/monitors.lua"; }
fresh '"auto"'; r=$(run_block 2940x1846@60 2)
check "new VM, MacBook Air (2940 px, Retina): scale 2 [$r]" "[[ '$r' == '2 2 2940x1846@60' ]]"
fresh '"auto"'; r=$(run_block 2940x1846@60)
check "new VM without the Mac's scale: 2 like UTM and Parallels [$r]" "[[ '$r' == '2 2 2940x1846@60' ]]"
fresh '"auto"'; r=$(run_block 2560x1440@60 1)
check "new VM, plain display at 1x: scale 1 [$r]" "[[ '$r' == '1 1 2560x1440@60' ]]"
fresh; r=$(run_block 3456x2160@120 2)
check "new VM, no monitors.lua yet: scale 2 [$r]" "[[ '$r' == '2 2 3456x2160@120' ]]"
fresh 1.6; r=$(run_block 2940x1846@60 2)
check "Omarchy VM with a scale chosen in its menu keeps it [$r]" "[[ '$r' == '1.6 2 2940x1846@60' ]]"
# Ours, then the user picks 1.25 in Omarchy's menu (its sed), then a later apply.
fresh '"auto"'; run_block 2940x1846@60 2 >/dev/null
sed -i '' -E -e 's|^local omarchy_monitor_scale = .*|local omarchy_monitor_scale = 1.25|' -e 's|^local omarchy_gdk_scale = .*|local omarchy_gdk_scale = 1|' "$t/home/.config/hypr/monitors.lua" 2>/dev/null ||
  sed -i -E -e 's|^local omarchy_monitor_scale = .*|local omarchy_monitor_scale = 1.25|' -e 's|^local omarchy_gdk_scale = .*|local omarchy_gdk_scale = 1|' "$t/home/.config/hypr/monitors.lua"
r=$(run_block 3024x1890@120)
check "later apply keeps the scale chosen in Omarchy's menu, mode follows the Mac [$r]" "[[ '$r' == '1.25 1 3024x1890@120' ]]"
# A prebuilt image made on a Mac at scale 1, first apply on a Retina Mac.
fresh '"auto"'; run_block 2560x1440@60 1 >/dev/null; r=$(run_block 2940x1846@60 2)
check "prebuilt image, first apply: the Mac's scale replaces the image's [$r]" "[[ '$r' == '2 2 2940x1846@60' ]]"
check "a bad SCALE is refused" "! bash $f nobody 2940x1846@60 'x;y' 2>/dev/null"
check "apply passes --display-scale to a new Fusion VM only" "grep -q 'TYPE == fusion ]] && (( FRESH )) && ds=\$(mac_tool mac-display --scale' src/cmd/apply.sh"
check "guest/install.sh hands the scale to Fusion's install.sh" "grep -q '\"\$R/fusion/guest/install.sh\" \"\$U\" \"\$MODE\" \${DSCALE:+\"\$DSCALE\"}' src/guest/install.sh"

(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
