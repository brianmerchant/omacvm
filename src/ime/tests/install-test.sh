#!/bin/bash
# The mac-ime feature's VM step (src/ime/guest/install.sh) without a VM: on
# builds and installs the Fcitx5 module once, then only checks it; a changed
# source or a new Fcitx5 builds it again; off removes only OmacVM's package,
# the port rule, the GTK line and the flag it added (never a flag the user
# set); the status line the check and the control centre show. pacman,
# makepkg, udevadm and systemctl are stand-ins; the VM's paths live under a
# scratch folder (OMACVM_IME_ROOT).
#   src/ime/tests/install-test.sh   (run.sh runs it too)
set -uo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
G=$R/src/ime/guest
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$T/state
mkdir -p "$T/bin"
digest() { (cd "$G" && cat addon/omacvmime.cpp addon/protocol.cpp addon/protocol.h addon/omacvmime.conf) | shasum -a 256 | cut -c1-16; }
SRC=$(digest)

cat > "$T/bin/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >> "$CALLS"
case $1 in
  -T) for p in "${@:2}"; do [[ " $MISSING " == *" $p "* ]] && echo "$p"; done; exit 0 ;;
  -Q) [[ -s $S/$2.ver ]] || exit 1; echo "$2 $(cat "$S/$2.ver")" ;;
  -Qi) [[ -s $S/$2.ver ]] || exit 1; printf 'Name            : %s\nPackager        : %s\n' "$2" "$(cat "$S/$2.packager")" ;;
  -Rns) for a in "${@:2}"; do [[ $a == -* ]] || { rm -f "$S/$a.ver"; [[ $a == omacvm-fcitx5-ime ]] && rm -f "$ROOT/usr/lib/omacvm-ime/build-info"; }; done ;;
  -U) for a in "$@"; do
        [[ $a == *.pkg.tar.* ]] || continue
        echo 1.0.0-1 > "$S/omacvm-fcitx5-ime.ver"; echo "OmacVM <omacvm@users.noreply.github.com>" > "$S/omacvm-fcitx5-ime.packager"
        mkdir -p "$ROOT/usr/lib/omacvm-ime"
        printf 'source %s\nfcitx5 %s\n' "$BUILT_SRC" "$(cat "$S/fcitx5.ver")" > "$ROOT/usr/lib/omacvm-ime/build-info"
      done ;;
esac
exit 0
EOF
cat > "$T/bin/sha256sum" <<'EOF'
#!/bin/bash
shasum -a 256 "$@"
EOF
cat > "$T/bin/udevadm" <<'EOF'
#!/bin/bash
echo "udevadm $*" >> "$CALLS"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
EOF
cat > "$T/bin/runuser" <<'EOF'
#!/bin/bash
echo "runuser $*" >> "$CALLS"
while [[ $1 != -- ]]; do shift; done; shift
exec "$@"
EOF
cat > "$T/bin/makepkg" <<'EOF'
#!/bin/bash
echo "makepkg $*" >> "$CALLS"
[[ $MAKEPKG == ok ]] || exit 1
for f in omacvmime.cpp protocol.cpp protocol.h omacvmime.conf; do [[ -f $f ]] || exit 1; done
: > "$PKGDEST/omacvm-fcitx5-ime-1.0.0-1-aarch64.pkg.tar.zst"
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/chown"
cat > "$T/bin/pkg-add" <<'EOF'
#!/bin/bash
echo "pkg-add $*" >> "$CALLS"
[[ $PKGADD == ok ]]
EOF
chmod +x "$T/bin/"*

ROOT=$T/root H=$T/root/home/me
run() {   # ARGS... ; env: INSTALLED BUILT_FOR FCITX MISSING MAKEPKG PKGADD KEEP
  if [[ -z ${KEEP:-} ]]; then
    rm -rf "$ROOT" "$S"; mkdir -p "$ROOT/var/log" "$ROOT/var/tmp" "$H/.config" "$S"
    [[ -n ${FCITX-5.1.23-1} ]] && echo "${FCITX-5.1.23-1}" > "$S/fcitx5.ver"
    if [[ -n ${INSTALLED:-} ]]; then
      echo 1.0.0-1 > "$S/omacvm-fcitx5-ime.ver"; echo "OmacVM <omacvm@users.noreply.github.com>" > "$S/omacvm-fcitx5-ime.packager"
      mkdir -p "$ROOT/usr/lib/omacvm-ime"
      printf 'source %s\nfcitx5 %s\n' "$INSTALLED" "${BUILT_FOR:-5.1.23-1}" > "$ROOT/usr/lib/omacvm-ime/build-info"
    fi
  fi
  : > "$T/calls"
  OUT=$(CALLS=$T/calls S=$S ROOT=$ROOT OMACVM_IME_ROOT=$ROOT BUILT_SRC=$SRC MISSING=${MISSING:-} MAKEPKG=${MAKEPKG:-ok} \
    PKGADD=${PKGADD:-ok} OMACVM_PKG_ADD=$T/bin/pkg-add PATH="$T/bin:$PATH" bash "$G/install.sh" me "$@" 2>&1); CODE=$?
}
called() { grep -qF -- "$1" "$T/calls" && echo yes || echo no; }
has() { [[ -e $1 ]] && echo yes || echo no; }

# ---------- status ----------
INSTALLED="" run --status
expect "status, not built: needed" "needed the Fcitx5 module is not built yet: omacvm apply" "$OUT"
INSTALLED=$SRC run --status
expect "status, built from these sources for this Fcitx5: ok" "ok Fcitx5 module for Fcitx5 5.1.23-1" "$OUT"
INSTALLED=0123456789abcdef run --status
expect "status, other sources: needed" "needed the Fcitx5 module is older than this OmacVM: omacvm apply" "$OUT"
INSTALLED=$SRC BUILT_FOR=5.1.22-1 run --status
expect "status, another Fcitx5: needed" "needed the Fcitx5 module was built for Fcitx5 5.1.22-1, the VM has 5.1.23-1: omacvm apply" "$OUT"
FCITX="" run --status
expect "status, no Fcitx5: needed" "needed Fcitx5 is not installed (Omarchy's input method): omacvm apply" "$OUT"

# ---------- on ----------
printf -- '--ozone-platform=wayland\n' > "$T/chromium"
run on
expect "on: builds and installs" "0 yes yes" "$CODE $(called makepkg) $(called 'pacman -U')"
expect "on: Fcitx5 restarted to load it" yes "$(called 'try-restart omarchy-fcitx5.service')"
expect "on: the port rule (uaccess)" yes "$(grep -q 'ATTR{name}=="org.omacvm.ime", TAG+="uaccess"' "$ROOT/etc/udev/rules.d/70-omacvm-ime.rules" && echo yes)"
expect "on: GTK through Fcitx5 from the next login" yes "$(grep -qx 'GTK_IM_MODULE=fcitx' "$H/.config/environment.d/90-omacvm-ime.conf" && echo yes)"
expect "on: says so" yes "$(grep -q 'Fcitx5 module for Fcitx5 5.1.23-1 (GTK apps and Chromium from the next login)' <<<"$OUT" && echo yes)"
expect "on: build folder gone" "" "$(ls "$ROOT/var/tmp")"

# Again: nothing built, nothing restarted.
KEEP=1 run on
expect "on again: no build, no restart" "0 no no" "$CODE $(called makepkg) $(called 'try-restart omarchy-fcitx5.service')"

# Chromium's flag: added once, only where the file exists, removed only if ours.
mkdir -p "$H/.config"; printf -- '--ozone-platform=wayland\n' > "$H/.config/chromium-flags.conf"
printf -- '--enable-wayland-ime\n--foo\n' > "$H/.config/electron-flags.conf"
KEEP=1 run on
expect "on: Chromium gets --enable-wayland-ime" "--ozone-platform=wayland
--enable-wayland-ime" "$(cat "$H/.config/chromium-flags.conf")"
KEEP=1 run on
expect "on twice: the flag once" 1 "$(grep -c -- --enable-wayland-ime "$H/.config/chromium-flags.conf")"
expect "on: a flag the user had stays theirs" "$H/.config/chromium-flags.conf" "$(cat "$H/.local/state/omacvm/ime-flags")"
expect "on: no brave file made" no "$(has "$H/.config/brave-flags.conf")"

# Build tools: installed for the build, removed after it.
MISSING="base-devel pkgconf" run on
expect "on, tools missing: installed as deps, removed after" "yes yes" "$(called 'pkg-add --asdeps base-devel pkgconf') $(called 'pacman -Rns --noconfirm base-devel pkgconf')"
MAKEPKG=fail run on
expect "on, build fails: exit 1, says where the log is" "1 yes" "$CODE $(grep -q "the build failed (details in $ROOT/var/log/omacvm-mac-ime.log)" <<<"$OUT" && echo yes)"
PKGADD=fail MISSING=pkgconf run on
expect "on, tools cannot be installed: exit 1" 1 "$CODE"
FCITX="" run on
expect "on without Fcitx5: exit 1, nothing built" "1 no" "$CODE $(called makepkg)"

# A new Fcitx5 or new sources: built again.
INSTALLED=$SRC BUILT_FOR=5.1.22-1 run on
expect "on, Fcitx5 updated: built again" "0 yes" "$CODE $(called makepkg)"
INSTALLED=0123456789abcdef run on
expect "on, sources changed: built again" "0 yes" "$CODE $(called makepkg)"

# ---------- off ----------
INSTALLED="" run off
expect "off, nothing there: silent, status 0, no restart" "0  no" "$CODE $OUT $(called try-restart)"
INSTALLED=$SRC run on
printf -- '--ozone-platform=wayland\n' > "$H/.config/chromium-flags.conf"
KEEP=1 run on
KEEP=1 run off
expect "off: package removed" "0 yes" "$CODE $(called 'pacman -Rns --noconfirm omacvm-fcitx5-ime')"
expect "off: rule, GTK line and marker gone" "no no no" "$(has "$ROOT/etc/udev/rules.d/70-omacvm-ime.rules") $(has "$H/.config/environment.d/90-omacvm-ime.conf") $(has "$H/.local/state/omacvm/ime-flags")"
expect "off: our flag removed, the user's kept" "--ozone-platform=wayland" "$(cat "$H/.config/chromium-flags.conf")"
expect "off: Fcitx5 restarted (the module goes)" yes "$(called 'try-restart omarchy-fcitx5.service')"
expect "off: then status says not built" "needed" "$(KEEP=1 run --status; echo "${OUT%% *}")"
printf 'someone <a@b>\n' > "$S/omacvm-fcitx5-ime.packager"; echo 1.0.0-1 > "$S/omacvm-fcitx5-ime.ver"
KEEP=1 run off
expect "off: a package of that name not built by OmacVM stays" no "$(called 'pacman -Rns')"

expect "usage: unknown action" 2 "$(run frob; echo "$CODE")"
expect "parts.tsv: ime/ is the feature's" yes "$(grep -q $'^mac-ime\time/\\*\\*$' "$R/src/release/parts.tsv" && echo yes)"
exit $fail
