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

# The package is the version the script waits for, and the distro's own wins later.
eval "$(grep -E '^(pkgname|epoch|pkgver|pkgrel)=' "$D/PKGBUILD")"
fixed=$(sed -n 's/^FIXED=\([^ ]*\).*/\1/p' "$D/vulkan-virtio.sh")
[[ $pkgname == vulkan-virtio && "$epoch:$pkgver" == "$fixed" ]] && pass "PKGBUILD is $fixed" ||
  fail "PKGBUILD $pkgname $epoch:$pkgver vs FIXED $fixed"
[[ $("$T/vercmp" "$epoch:$pkgver-$pkgrel" "$epoch:$pkgver-1") == -1 ]] && pass "the distro's $pkgver-1 replaces ours" ||
  fail "ours ($pkgrel) is not older than the distro's $pkgver-1"
grep -q "^sha256sums=('[0-9a-f]\{64\}')" "$D/PKGBUILD" && pass "source pinned by sha256" || fail "source not pinned"

# Wired in: apply's app step runs it, check reads it.
grep -q '^venus/vulkan-virtio.sh ||' src/app/guest/install.sh && pass "app install runs it" || fail "app install does not run it"
grep -q 'app/guest/venus/vulkan-virtio.sh --status' src/guest/check.sh && pass "check has the Vulkan (Venus) row" || fail "no check row"

(( fails == 0 )) && echo "venus-driver: all ok" || { echo "venus-driver: $fails failed"; exit 1; }
