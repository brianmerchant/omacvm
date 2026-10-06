#!/bin/bash
# vulkan-virtio.sh (as root, in an OmacVM.app VM): Vulkan through Venus on a
# stock Omarchy. When the app's Vulkan switch is on, the Mac sizes GPU memory
# in its 16 KiB pages (virtio-gpu blob alignment). Arch Linux ARM's Mesa 26.2.3
# Venus driver does not, the guest kernel refuses its first blob and every
# Vulkan app fails with "vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY".
# Mesa 26.2.4 does. Until Arch Linux ARM ships it, this builds the distro's
# vulkan-virtio package from Mesa 26.2.4 (PKGBUILD here, Venus only, a few
# minutes) and installs it with pacman; the distro's 26.2.4 or newer replaces
# it on the next pacman -Syu. OpenGL stays on the distro's Mesa.
#   vulkan-virtio.sh            install it if this VM needs it (silent when Vulkan is off)
#   vulkan-virtio.sh --want     install it also before the VM has Vulkan (omacvm apply,
#                               when the VM's Graphics setting gives it Vulkan here)
#   vulkan-virtio.sh --ready    exit 0 if the VM has a Venus driver for 16 KiB pages
#                               (this package from 26.2.4 on, or OmacVM's Mesa)
#   vulkan-virtio.sh --status   one line: STATE DETAIL, STATE one of
#                               ok | needed | no-venus | no-pages (nothing to do)
# Tests: OMACVM_VENUS_PROBE replaces the probe's output ("venus=1 blob_alignment=16384").
set -euo pipefail
cd "$(dirname "$0")"
# Packages only through guest/pkg-add: never an update of one the VM has.
# When the VM's packages are too old for that, --want updates the whole
# system first (guest/system-update: omarchy update, then the GBM test).
PKG_ADD=${OMACVM_PKG_ADD:-$PWD/../../../guest/pkg-add}
SYSTEM_UPDATE=${OMACVM_SYSTEM_UPDATE:-$PWD/../../../guest/system-update}
FIXED=1:26.2.4                       # the first Venus driver that honours blob alignment
LOG=/var/log/omacvm-vulkan-virtio.log

status() {
  local p venus align have
  p=${OMACVM_VENUS_PROBE:-$(python3 ./venus-probe.py 2>/dev/null || echo "venus=0 blob_alignment=0")}
  venus=$(sed -n 's/.*venus=\([0-9]*\).*/\1/p' <<<"$p"); align=$(sed -n 's/.*blob_alignment=\([0-9]*\).*/\1/p' <<<"$p")
  have=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{ print $2 }' || true)
  if [[ ${venus:-0} != 1 ]]; then
    echo "no-venus Vulkan is off in OmacVM.app for this VM${have:+ (vulkan-virtio $have)}"
  elif (( ${align:-0} <= 4096 )); then
    echo "no-pages the GPU needs no page alignment here${have:+ (vulkan-virtio $have)}"
  elif [[ -n $have ]] && (( $(vercmp "$have" "$FIXED") >= 0 )); then
    echo "ok vulkan-virtio $have sizes GPU memory to ${align}-byte pages"
  else
    echo "needed vulkan-virtio ${have:-not installed} cannot size GPU memory to ${align}-byte pages (needs ${FIXED#*:})"
  fi
}

# The VM's Venus driver sizes GPU memory to 16 KiB pages (with or without the
# Venus device now): the Mac's Automatic Graphics waits for this.
ready() {
  local have
  [[ -f ${OMACVM_MESA_ICD:-/etc/vulkan/icd.d/omacvm_venus_icd.json} ]] && return 0
  have=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{ print $2 }' || true)
  [[ -n $have ]] && (( $(vercmp "$have" "$FIXED") >= 0 ))
}

case ${1:-} in
  --status) status; exit 0 ;;
  --ready) ready; exit ;;
  --want|"") ;;
  *) echo "usage: vulkan-virtio.sh [--want | --ready | --status]" >&2; exit 2 ;;
esac
s=$(status)
case ${s%% *} in
  needed) ;;
  ok) echo "Vulkan (Venus): ${s#* }"; exit 0 ;;
  *) [[ ${1:-} == --want ]] && ! ready || exit 0 ;;
esac
(( EUID == 0 )) || { echo "vulkan-virtio.sh: run as root" >&2; exit 1; }

# From the boot timer (OMACVM_VENUS_BOOT): the unit does not wait for the
# network or for the user's own pacman, so this does, for a while.
if [[ -n ${OMACVM_VENUS_BOOT:-} ]]; then
  for _ in $(seq 60); do getent hosts archive.mesa3d.org >/dev/null && break; sleep 5; done
  for _ in $(seq 120); do [[ -e /var/lib/pacman/db.lck ]] || break; sleep 5; done
  [[ -e /var/lib/pacman/db.lck ]] && { echo "Vulkan (Venus): pacman is busy, trying again at the next boot"; exit 0; }
fi
echo "Vulkan (Venus): building Mesa's vulkan-virtio ${FIXED#*:} (a few minutes, log $LOG)"
# Build tools this VM lacks are added for the build and removed after.
deps=(base-devel) rdeps=()
while IFS= read -r d; do rdeps+=("$d"); done < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${depends[@]}"')
while IFS= read -r d; do deps+=("$d"); done < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${makedepends[@]}"')
deps+=("${rdeps[@]}")
missing=$(pacman -T "${deps[@]}" || true)
B=$(mktemp -d /var/tmp/omacvm-vulkan-virtio.XXXXXX)
cleanup() {
  local added
  # shellcheck disable=SC2086 # one package per word
  added=$([[ -z $missing ]] || pacman -Qq $missing 2>/dev/null || true)
  # The driver's own dependencies (vulkan-mesa-implicit-layers) stay with it:
  # pacman refuses the whole -Rns otherwise.
  if [[ -n $added ]] && pacman -Q vulkan-virtio >/dev/null 2>&1; then
    added=$(grep -vxF -f <(printf '%s\n' "${rdeps[@]}") <<<"$added" || true)
  fi
  rm -rf "$B"
  if [[ -n $added ]]; then
    # shellcheck disable=SC2086 # one package per word
    pacman -Rns --noconfirm $added >>"$LOG" 2>&1 || echo "Vulkan (Venus): build tools left installed (pacman -Rns did not take them all)"
  fi
}
trap cleanup EXIT
fail() { echo "Vulkan (Venus): $1 (OpenGL is unaffected; details in $LOG)" >&2; exit 1; }
add_tools() {   # pkg-add's status; its line in $B/pkg-add.err
  [[ -n $missing ]] || return 0
  # shellcheck disable=SC2086 # one package per word
  "$PKG_ADD" --asdeps $missing 2>"$B/pkg-add.err"
}
: > "$LOG"
rc=0; add_tools || rc=$?
# The VM's package list is older than the mirrors (they 404), or the tools
# need newer versions of what the VM has: a prebuilt VM a day or more after
# its image. Graphics -> Vulkan (--want) updates the whole system first.
if (( rc == 3 )) && [[ ${1:-} == --want ]]; then
  echo "Vulkan (Venus): the build tools need a newer system than the VM has (Arch Linux ARM moved on): updating the whole system first"
  urc=0; "$SYSTEM_UPDATE" || urc=$?
  # 2: updated, but the desktop's graphics would not start (system-update said so).
  (( urc != 2 )) || { echo "Vulkan (Venus): stopped before the build: the graphics need fixing first" >&2; exit 1; }
  (( urc == 0 )) || fail "stopped: the VM's system update did not go through (see above)"
  # The update can bring the distro's own fixed driver: nothing to build then.
  if ready; then
    echo "Vulkan (Venus): the update brought $(pacman -Q vulkan-virtio 2>/dev/null || echo "a Venus driver") for 16 KiB pages, nothing to build"
    exit 0
  fi
  echo "Vulkan (Venus): system updated; building Mesa's vulkan-virtio ${FIXED#*:} now"
  missing=$(pacman -T "${deps[@]}" || true)
  rc=0; add_tools || rc=$?
fi
if (( rc )); then
  cat "$B/pkg-add.err" >&2
  fail "the build tools are not installed"
fi
install -m644 PKGBUILD "$B/"
chown -R nobody: "$B"
# makepkg refuses root: build as nobody (it downloads and checks the sha256 itself).
( cd "$B" && runuser -u nobody -- env HOME="$B" PKGDEST="$B" BUILDDIR="$B/build" SRCDEST="$B" LOGDEST="$B" PACKAGER="OmacVM <omacvm@users.noreply.github.com>" \
    makepkg --nodeps --noconfirm --noprogressbar ) >>"$LOG" 2>&1 || fail "the build failed"
pkg=""
# name-epoch:pkgver-pkgrel-arch
for f in "$B"/vulkan-virtio-"$FIXED"-*-aarch64.pkg.tar.*; do [[ -f $f ]] && pkg=$f; done
[[ -n $pkg ]] || fail "the build made no package"
# Keep how the distro's package was installed (a dependency of Omarchy's, or by hand).
reason=--asexplicit
LC_ALL=C pacman -Qi vulkan-virtio 2>/dev/null | grep -q '^Install Reason *: Installed as a dependency' && reason=--asdeps
pacman -U --noconfirm "$reason" "$pkg" >>"$LOG" 2>&1 || fail "pacman could not install $(basename "$pkg")"
s=$(status)
if [[ ${s%% *} == no-venus || ${s%% *} == no-pages ]]; then
  ready || fail "installed, but it is not ${FIXED#*:} or newer"
  echo "Vulkan (Venus): vulkan-virtio $(pacman -Q vulkan-virtio | awk '{ print $2 }') ready for the VM's next start"
  exit 0
fi
[[ ${s%% *} == ok ]] || fail "installed, but: ${s#* }"
echo "Vulkan (Venus): ${s#* } (restart Vulkan apps)"
