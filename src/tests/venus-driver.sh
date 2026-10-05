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
grep -q 'app/guest/venus/vulkan-virtio.sh --status' src/guest/check.sh && pass "check has the Vulkan (Venus) row" || fail "no check row"

# Vulkan windows present through a CPU copy: a dma-buf from Venus imported by
# Hyprland's virgl context loses that context (PIPE_RESOURCE_SET_TYPE EINVAL).
grep -qx 'MESA_VK_WSI_DEBUG=sw' src/app/guest/90-omacvm-vulkan.conf &&
  grep -q 'environment.d/90-omacvm-vulkan.conf' src/app/guest/install.sh && pass "Vulkan presents in software WSI" ||
  fail "no software WSI for Vulkan (Hyprland would lose its GPU context)"

(( fails == 0 )) && echo "venus-driver: all ok" || { echo "venus-driver: $fails failed"; exit 1; }
