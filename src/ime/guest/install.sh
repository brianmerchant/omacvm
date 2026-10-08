#!/bin/bash
# The Mac's input methods in Omarchy (feature mac-ime, OmacVM.app only,
# experimental; docs/adr/0042-mac-ime.md), as root in the VM:
#   install.sh USER on        build and install the Fcitx5 module if it is missing
#                             or older, the port rule, GTK through Fcitx5 and the
#                             Chromium/Electron flag (both from the next login)
#   install.sh USER off       remove all of that again (silent when nothing is there)
#   install.sh USER --status  one line: STATE DETAIL, STATE one of ok | off | needed
# The module (package omacvm-fcitx5-ime) is built here against the VM's own
# Fcitx5, from the sources in addon/; it is built again when they change or
# Fcitx5's version does. Tests: src/ime/tests/install-test.sh (OMACVM_IME_ROOT
# puts every path under a scratch folder; pacman, makepkg, udevadm and
# systemctl are stand-ins there).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh USER on|off|--status}; ACTION=${2:?usage: install.sh USER on|off|--status}
ROOT=${OMACVM_IME_ROOT:-}
H=$ROOT$(getent passwd "$U" 2>/dev/null | cut -d: -f6 || true)
[[ $H != "$ROOT" ]] || H=$ROOT/home/$U
PKG=omacvm-fcitx5-ime
PACKAGER="OmacVM <omacvm@users.noreply.github.com>"
INFO=$ROOT/usr/lib/omacvm-ime/build-info
RULE=$ROOT/etc/udev/rules.d/70-omacvm-ime.rules
ENVD=$H/.config/environment.d/90-omacvm-ime.conf
MARK=$H/.local/state/omacvm/ime-flags
FLAG=--enable-wayland-ime
LOG=$ROOT/var/log/omacvm-mac-ime.log
PKG_ADD=${OMACVM_PKG_ADD:-$PWD/../../guest/pkg-add}
SOURCES=(addon/omacvmime.cpp addon/protocol.cpp addon/protocol.h addon/omacvmime.conf)

ours() { local i; i=$(pacman -Qi "$PKG" 2>/dev/null) || return 1; grep -q "^Packager *: $PACKAGER" <<<"$i"; }
source_digest() { cat "${SOURCES[@]}" | sha256sum | cut -c1-16; }
fcitx_version() { pacman -Q fcitx5 2>/dev/null | awk '{ print $2 }' || true; }
built() { sed -n "s/^$1 //p" "$INFO" 2>/dev/null || true; }

status() {
  local fv; fv=$(fcitx_version)
  if [[ -z $fv ]]; then echo "needed Fcitx5 is not installed (Omarchy's input method): omacvm apply"
  elif ! ours; then echo "needed the Fcitx5 module is not built yet: omacvm apply"
  elif [[ $(built source) != "$(source_digest)" ]]; then echo "needed the Fcitx5 module is older than this OmacVM: omacvm apply"
  elif [[ $(built fcitx5) != "$fv" ]]; then echo "needed the Fcitx5 module was built for Fcitx5 $(built fcitx5), the VM has $fv: omacvm apply"
  else echo "ok Fcitx5 module for Fcitx5 $fv"; fi
}

# Omarchy's Fcitx5 loads modules at its start: restarted when the module came
# or went (only while the desktop session runs it).
restart_fcitx() {
  systemctl --user -M "$U@" try-restart omarchy-fcitx5.service >/dev/null 2>&1 || true
}

flags_on() {
  local f
  install -d -o "$U" -g "$U" "$(dirname "$MARK")" 2>/dev/null || mkdir -p "$(dirname "$MARK")"
  for f in "$H/.config/chromium-flags.conf" "$H/.config/chrome-flags.conf" "$H/.config/brave-flags.conf" "$H/.config/electron-flags.conf"; do
    [[ -f $f ]] || continue
    grep -qxF -- "$FLAG" "$f" && continue
    printf '%s\n' "$FLAG" >> "$f"
    grep -qxF "$f" "$MARK" 2>/dev/null || echo "$f" >> "$MARK"
  done
  [[ ! -f $MARK ]] || chown "$U:$U" "$MARK" 2>/dev/null || true
}

flags_off() {
  local f
  [[ -f $MARK ]] || return 0
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    # The file without our line (owner and mode kept; no sed -i: GNU and BSD differ).
    { grep -vxF -- "$FLAG" "$f" || true; } > "$f.omacvm-new"
    cat "$f.omacvm-new" > "$f"; rm -f "$f.omacvm-new"
  done < "$MARK"
  rm -f "$MARK"
}

case $ACTION in
  --status) status; exit 0 ;;
  on|off) ;;
  *) echo "usage: install.sh USER on|off|--status" >&2; exit 2 ;;
esac
(( EUID == 0 )) || [[ -n $ROOT ]] || { echo "mac input methods: run as root" >&2; exit 1; }

if [[ $ACTION == off ]]; then
  changed=0
  if ours; then
    echo "Mac input methods: removing the Fcitx5 module"
    pacman -Rns --noconfirm "$PKG" >>"$LOG" 2>&1 || { echo "Mac input methods: pacman could not remove $PKG (details in $LOG)" >&2; exit 1; }
    changed=1
  fi
  if [[ -f $RULE ]]; then rm -f "$RULE"; udevadm control --reload >/dev/null 2>&1 || true; fi
  rm -f "$ENVD"
  flags_off
  (( ! changed )) || restart_fcitx
  exit 0
fi

# The port: the desktop user's (the user Fcitx5 runs as), as the clipboard's.
if ! cmp -s 70-omacvm-ime.rules "$RULE"; then
  mkdir -p "$(dirname "$RULE")"
  install -m644 70-omacvm-ime.rules "$RULE"
  udevadm control --reload >/dev/null 2>&1 || true
  udevadm trigger --subsystem-match=virtio-ports >/dev/null 2>&1 || true
fi
# GTK apps (ghostty, Nautilus) through Fcitx5's own GTK module: it gives the
# caret's place; Wayland's text-input does not. Chromium and Electron reach
# an input method only with this flag. Both from the next login.
if [[ ! -f $ENVD ]] || ! grep -qxF 'GTK_IM_MODULE=fcitx' "$ENVD"; then
  mkdir -p "$(dirname "$ENVD")"
  printf '# OmacVM mac-ime: GTK apps type through Fcitx5 (omacvm disable mac-ime removes this file).\nGTK_IM_MODULE=fcitx\n' > "$ENVD"
  chown -R "$U:$U" "$H/.config/environment.d" 2>/dev/null || true
fi
flags_on

s=$(status)
if [[ ${s%% *} == ok ]]; then
  echo "Mac input methods: ${s#* }"; exit 0
fi
[[ -n $(fcitx_version) ]] || { echo "Mac input methods: ${s#* }" >&2; exit 1; }

echo "Mac input methods: building the Fcitx5 module (under a minute, log $LOG)"
deps=(base-devel)
while IFS= read -r d; do deps+=("$d"); done < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${makedepends[@]}"')
missing=$(pacman -T "${deps[@]}" || true)
B=$(mktemp -d "$ROOT/var/tmp/omacvm-ime.XXXXXX")
cleanup() {
  rm -rf "$B"
  if [[ -n $missing ]]; then
    # shellcheck disable=SC2086 # one package per word
    pacman -Rns --noconfirm $missing >>"$LOG" 2>&1 || echo "Mac input methods: build tools left installed (pacman -Rns did not take them all)"
  fi
}
trap cleanup EXIT
fail() { echo "Mac input methods: $1 (details in $LOG)" >&2; exit 1; }
: > "$LOG"
if [[ -n $missing ]]; then
  # shellcheck disable=SC2086 # one package per word
  "$PKG_ADD" --asdeps $missing || fail "the build tools are not installed"
fi
install -m644 PKGBUILD "${SOURCES[@]}" "$B/"
chown -R nobody: "$B" 2>/dev/null || [[ -n $ROOT ]]
# makepkg refuses root: build as nobody.
( cd "$B" && runuser -u nobody -- env HOME="$B" PKGDEST="$B" BUILDDIR="$B/build" SRCDEST="$B" LOGDEST="$B" PACKAGER="$PACKAGER" \
    makepkg --nodeps --noconfirm --noprogressbar ) >>"$LOG" 2>&1 || fail "the build failed"
pkg=""
for f in "$B/$PKG"-*-aarch64.pkg.tar.*; do [[ -f $f ]] && pkg=$f; done
[[ -n $pkg ]] || fail "the build made no package"
pacman -U --noconfirm "$pkg" >>"$LOG" 2>&1 || fail "pacman could not install $(basename "$pkg")"
s=$(status)
[[ ${s%% *} == ok ]] || fail "installed, but: ${s#* }"
restart_fcitx
echo "Mac input methods: ${s#* } (GTK apps and Chromium from the next login)"
