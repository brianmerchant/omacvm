#!/bin/bash
# Offline test of src/app/guest/venus (no VM): when an OmacVM.app VM gets the
# Venus driver built from Mesa 26.2.4, and that the package, the installer and
# the check agree. The real build and Vulkan run are tested in a VM (see
# docs/routes/app.md, "Vulkan").
set -u
cd "$(dirname "$0")/../.." || exit 1
D=src/app/guest/venus
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Stand-ins for pacman and vercmp (pacman's own version order for these cases).
cat > "$T/pacman" <<'EOF'
#!/bin/bash
[[ $1 == -Q && -n ${HAVE:-} ]] && { echo "vulkan-virtio $HAVE"; exit 0; }
exit 1
EOF
cat > "$T/vercmp" <<'EOF'
#!/usr/bin/env python3
import re, sys
def key(v):
    e, _, v = v.rpartition(":")
    v, _, r = v.partition("-")
    num = lambda s: [int(x) for x in re.findall(r"\d+", s)]
    return (int(e or 0), num(v), num(r))
a, b = key(sys.argv[1]), key(sys.argv[2])
print((a > b) - (a < b))
EOF
chmod +x "$T/pacman" "$T/vercmp"

st() {   # PROBE HAVE -> the state word
  PATH="$T:$PATH" OMACVM_VENUS_PROBE=$1 HAVE=$2 "$D/vulkan-virtio.sh" --status | cut -d' ' -f1
}
expect() {   # NAME PROBE HAVE WANT
  local got; got=$(st "$2" "$3")
  [[ $got == "$4" ]] && pass "$1: $4" || fail "$1: got '$got', want '$4'"
}
V="venus=1 blob_alignment=16384"
expect "Vulkan off in the app"           "venus=0 blob_alignment=0" "1:26.2.3-1"   no-venus
expect "4 KiB pages (no alignment)"      "venus=1 blob_alignment=4096" "1:26.2.3-1" no-pages
expect "old kernel (alignment unknown)"  "venus=1 blob_alignment=0" "1:26.2.3-1"    no-pages
expect "Arch Linux ARM's 26.2.3"         "$V" "1:26.2.3-1"   needed
expect "no Venus driver at all"          "$V" ""             needed
expect "ours (26.2.4-0.1)"               "$V" "1:26.2.4-0.1" ok
expect "the distro's 26.2.4"             "$V" "1:26.2.4-1"   ok
expect "a newer Mesa"                    "$V" "1:26.3.1-2"   ok

# Nothing to do -> silent, exit 0, also as a normal user (apply runs it on every app VM).
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "Vulkan off: silent" || fail "Vulkan off: rc $rc, said '$out'"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="$V" HAVE=1:26.2.4-1 "$D/vulkan-virtio.sh" 2>&1); rc=$?
[[ $rc == 0 && $out == "Vulkan (Venus): vulkan-virtio 1:26.2.4-1 sizes GPU memory to 16384-byte pages" ]] &&
  pass "already fixed: one line" || fail "already fixed: rc $rc, said '$out'"

# --ready (the Mac's Automatic waits for it) and --want (omacvm apply, when the
# VM's Graphics gives it Vulkan: built also before the VM has the Venus device).
rd() { PATH="$T:$PATH" HAVE=$1 OMACVM_MESA_ICD=$T/${2:-none}.json "$D/vulkan-virtio.sh" --ready; echo $?; }
[[ $(rd 1:26.2.3-1) == 1 ]] && pass "--ready: 26.2.3 is not" || fail "--ready said yes to 26.2.3"
[[ $(rd "") == 1 ]] && pass "--ready: no driver is not" || fail "--ready said yes without a driver"
[[ $(rd 1:26.2.4-0.1) == 0 ]] && pass "--ready: ours" || fail "--ready said no to 26.2.4-0.1"
[[ $(rd 1:26.3.0-1) == 0 ]] && pass "--ready: a newer distro Mesa" || fail "--ready said no to 26.3.0"
: > "$T/icd.json"
[[ $(rd 1:26.2.3-1 icd) == 0 ]] && pass "--ready: OmacVM's Mesa (vulkan feature)" || fail "--ready said no with OmacVM's Mesa"
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.4-0.1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
[[ $rc == 0 && -z $out ]] && pass "--want, driver there, no Venus yet: silent" || fail "--want with the driver: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 OMACVM_MESA_ICD=$T/none.json "$D/vulkan-virtio.sh" --want 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* ]] && pass "--want, 26.2.3, no Venus yet: builds (root only)" ||
    fail "--want did not go to the build: rc $rc, said '$out'"
fi
out=$(PATH="$T:$PATH" OMACVM_VENUS_PROBE="venus=0 blob_alignment=0" HAVE=1:26.2.3-1 "$D/vulkan-virtio.sh" --nonsense 2>&1); rc=$?
[[ $rc == 2 ]] && pass "unknown option: usage" || fail "unknown option: rc $rc"

# The package is the version the script waits for, and the distro's own wins later.
eval "$(grep -E '^(pkgname|epoch|pkgver|pkgrel)=' "$D/PKGBUILD")"
fixed=$(sed -n 's/^FIXED=\([^ ]*\).*/\1/p' "$D/vulkan-virtio.sh")
[[ $pkgname == vulkan-virtio && "$epoch:$pkgver" == "$fixed" ]] && pass "PKGBUILD is $fixed" ||
  fail "PKGBUILD $pkgname $epoch:$pkgver vs FIXED $fixed"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:$pkgver-1") == -1 ]] && pass "the distro's $pkgver-1 replaces ours" ||
  fail "ours ($pkgrel) is not older than the distro's $pkgver-1"
grep -q "^sha256sums=('[0-9a-f]\{64\}')" "$D/PKGBUILD" && pass "source pinned by sha256" || fail "source not pinned"

# Wired in: apply's app step runs it, check reads it.
grep -q '^venus/vulkan-virtio.sh $want ||' src/app/guest/install.sh && pass "app install runs it" || fail "app install does not run it"
grep -q 'OMACVM_GRAPHICS=//p' src/app/guest/install.sh && pass "app install builds ahead for Graphics Vulkan" || fail "app install ignores OMACVM_GRAPHICS"
grep -q 'ExecStart=/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh$' "$D/omacvm-venus-driver.service" &&
  grep -q 'omacvm-venus-driver.service' src/app/guest/install.sh && pass "boot unit runs it" || fail "no boot unit"
# Never in the boot's critical chain: a timer after the desktop, no
# network-online.target and no [Install] on the service (a build at boot made
# multi-user.target, and with it the desktop, wait for it).
svc=$D/omacvm-venus-driver.service tmr=$D/omacvm-venus-driver.timer
if ! grep -v '^#' "$svc" | grep -q 'network-online' && ! grep -q '^\[Install\]' "$svc" && grep -q '^OnBootSec=' "$tmr" &&
   grep -q '^WantedBy=timers.target' "$tmr" && grep -q 'systemctl enable omacvm-venus-driver.timer' src/app/guest/install.sh &&
   grep -q 'rm -f /etc/systemd/system/multi-user.target.wants/omacvm-venus-driver.service' src/app/guest/install.sh; then
  pass "driver unit runs from a timer after boot, without network-online"
else
  fail "driver unit can delay the boot (network-online, [Install] on the service, or no timer)"
fi
grep -q 'app/guest/venus/vulkan-virtio.sh --status' src/guest/check.sh && pass "check has the Vulkan (Venus) row" || fail "no check row"

# OpenCL on that Vulkan (venus/opencl.sh): apply sets it up for Graphics Vulkan, off for OpenGL,
# leaves it to the vulkan feature's Mesa when that is there; omacvm graphics does it too.
grep -q '^if \[\[ $graphics == vulkan \]\]; then venus/opencl.sh ||' src/app/guest/install.sh &&
  grep -q 'venus/opencl.sh --off' src/app/guest/install.sh && pass "app install sets up OpenCL with Vulkan" ||
  fail "app install does not run venus/opencl.sh"
grep -q 'app/guest/venus/opencl.sh' src/cmd/graphics.sh && pass "omacvm graphics sets up OpenCL" || fail "omacvm graphics skips OpenCL"
grep -q '90-omacvm-opencl.conf' src/guest/check.sh && pass "check has the OpenCL row" || fail "no OpenCL check row"
O=$T/opencl.conf
OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" --nonsense >/dev/null 2>&1
[[ $? == 2 ]] && pass "opencl.sh: unknown option: usage" || fail "opencl.sh: unknown option accepted"
echo RUSTICL_ENABLE=zink > "$O"
OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" --off && [[ ! -e $O ]] &&
  pass "opencl.sh --off removes the switch" || fail "opencl.sh --off kept the switch"
echo RUSTICL_ENABLE=zink > "$O"; : > "$T/ours.icd"
out=$(OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/ours.icd "$D/opencl.sh" 2>&1); rc=$?
[[ $rc == 0 && ! -e $O && $out == *"feature vulkan"* ]] && pass "opencl.sh: OmacVM's Mesa has its own rusticl" ||
  fail "opencl.sh with OmacVM's Mesa: rc $rc, said '$out'"
if (( EUID != 0 )); then
  out=$(OMACVM_OPENCL_ENV=$O OMACVM_MESA_CLICD=$T/none.icd "$D/opencl.sh" 2>&1); rc=$?
  [[ $rc == 1 && $out == *"run as root"* && ! -e $O ]] && pass "opencl.sh installs as root only" ||
    fail "opencl.sh as a user: rc $rc, said '$out'"
fi

# Vulkan windows: Mesa's normal WSI when the app says it shows them (omacvm.vkwindows=1),
# else the software WSI (an older app ended Hyprland's GPU context on the import).
G=src/app/guest/omacvm-vulkan-present
d=$(mktemp -d)
sed "s#/run/omacvm/host.env#$d/host.env#" "$G" > "$d/gen"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "no host.env: software WSI" || fail "no host.env: not software WSI"
echo OMACVM_VKWINDOWS=1 > "$d/host.env"
[[ -z $(sh "$d/gen") ]] && pass "app shows Vulkan windows: normal WSI" || fail "app shows Vulkan windows: still software WSI"
printf 'OMACVM_SCREEN=2056x1329\nOMACVM_VKWINDOWS=0\n' > "$d/host.env"
[[ $(sh "$d/gen") == MESA_VK_WSI_DEBUG=sw ]] && pass "flag 0: software WSI" || fail "flag 0: not software WSI"
rm -rf "$d"
grep -q 'user-environment-generators/90-omacvm-vulkan-present' src/app/guest/install.sh &&
  grep -q 'rm -f /etc/environment.d/90-omacvm-vulkan.conf' src/app/guest/install.sh && pass "installed as a session generator" ||
  fail "generator not installed (or the old fixed file kept)"
grep -q 'value=omacvm.vkwindows=1' app/app/Sources/OmacVM/Runner.swift && pass "the app sends omacvm.vkwindows" ||
  fail "the app does not send omacvm.vkwindows"
grep -q '^Before=systemd-user-sessions.service' src/app/guest/omacvm-app-host.service && pass "host.env is written before sessions" ||
  fail "host.env may come after the session starts"
grep -q 'virgl-set-type-without-egl.patch' app/runtime/build-qemu-gpu-runtime.sh && pass "the runtime has the import patch" ||
  fail "the runtime lacks virgl-set-type-without-egl.patch"

(( fails == 0 )) && echo "venus-driver: all ok" || { echo "venus-driver: $fails failed"; exit 1; }
