#!/bin/bash
# OmacVM.app: hyprpicker that draws only when something changed
# (redraw-on-change.patch). Omarchy freezes the screen for screenshots and the
# screen recording picker with `hyprpicker -r -z`, and hyprpicker drew every
# display again on every frame, 60 to 120 times a second: each time Hyprland
# uploads the whole screen to the Mac's GPU through QEMU's main loop (21.6 MB a
# frame for a 2940x1840 display), which also runs the VM's sound. The patched
# build draws each display once and again only when the pointer enters or
# leaves it (or, with the zoom, when it moves).
# Run as root inside the VM:
#   build.sh [--hook] [desktop-user]
# Builds the release of the installed hyprpicker package (its version's tag,
# checked after the download) as the desktop user into /usr/local/bin, which
# comes before /usr/bin on the PATH; the package's binary stays as it is. Does
# nothing when that build is there already. A pacman hook (--hook: no pacman
# calls, its database is locked then) runs it again after hyprpicker upgrades.
# Whatever fails (no network, the patch no longer applies to a new release, the
# build) removes the OmacVM build, so the package's own hyprpicker runs: never a
# stale one. About a minute on 4 vCPUs. OMACVM_REBUILD_HYPRPICKER=1 builds anyway.
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
HOOK=0; [[ ${1:-} == --hook ]] && { HOOK=1; shift; }
OUT=/usr/local/bin/hyprpicker
STATE=/var/lib/omacvm/hyprpicker          # "<package version> <sha256 of $OUT> <sha256 of the patch>"
W=/var/cache/omacvm/hyprpicker
DEPS=(base-devel git cmake hyprwayland-scanner wayland-protocols)
U=${1:-$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env 2>/dev/null | tail -1)}

fail() {
  echo "hyprpicker: $* (the package's hyprpicker stays; screenshots work, the frozen screen costs more)" >&2
  rm -f "$OUT" "$STATE"
  exit 0
}

pkg=$(pacman -Q hyprpicker 2>/dev/null | awk '{ print $2 }')
if [[ -z $pkg ]]; then
  rm -f "$OUT" "$STATE"
  echo "hyprpicker: not installed, nothing to build"
  exit 0
fi
sum() { sha256sum "$1" | awk '{ print $1 }'; }
if [[ -z ${OMACVM_REBUILD_HYPRPICKER:-} && -x $OUT && -f $STATE &&
      $(cat "$STATE") == "$pkg $(sum "$OUT") $(sum "$here/redraw-on-change.patch")" ]]; then
  echo "hyprpicker $pkg: OmacVM build in place"
  exit 0
fi
[[ -n $U ]] && id "$U" >/dev/null 2>&1 || fail "no desktop user in /etc/omacvm/env"
ver=${pkg%-*}; ver=${ver#*:}
[[ $ver =~ ^[0-9]+(\.[0-9]+)+$ ]] || fail "unexpected package version $pkg"

if (( ! HOOK )); then "$here/../../../guest/pkg-add" "${DEPS[@]}" || fail "build tools not installed"; fi
for t in cmake git hyprwayland-scanner c++; do
  command -v "$t" >/dev/null || fail "$t missing"
done
rm -rf "$W"; install -d -o "$U" -g "$U" "$W"; mkdir -p "$(dirname "$STATE")"
as_u() { sudo -u "$U" env HOME="$W" "$@"; }
cd "$W" || fail "no work folder"
as_u git -c advice.detachedHead=false clone -q --depth 1 --branch "v$ver" \
  https://github.com/hyprwm/hyprpicker src 2>/dev/null || fail "cannot download hyprpicker v$ver"
cd src || fail "no source"
# the tag must be the release the package was built from
[[ $(as_u git describe --tags --exact-match 2>/dev/null) == "v$ver" ]] || fail "downloaded source is not v$ver"
as_u git apply --check "$here/redraw-on-change.patch" 2>/dev/null ||
  fail "the redraw fix does not apply to hyprpicker $ver (omacvm update may bring a newer one)"
as_u git apply "$here/redraw-on-change.patch"
echo "building hyprpicker $ver with the redraw fix (about a minute)"
as_u cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local > "$W/build.log" 2>&1 &&
  as_u cmake --build build -j"$(nproc)" >> "$W/build.log" 2>&1 ||
  { tail -20 "$W/build.log" >&2; fail "the build failed, full log: $W/build.log"; }
[[ -x build/hyprpicker ]] || fail "no hyprpicker binary after the build"
build/hyprpicker --help >/dev/null 2>&1 || fail "the built hyprpicker does not start"
install -o root -g root -m755 build/hyprpicker "$OUT"
echo "$pkg $(sum "$OUT") $(sum "$here/redraw-on-change.patch")" > "$STATE"
cd /; rm -rf "$W/src"
echo "hyprpicker $ver: OmacVM build installed ($OUT)"
