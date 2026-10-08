#!/bin/bash
# Offline test (no VM) of what an update from an older OmacVM leaves in the
# VM, after the Mac mini of 2026-10-08 (2.9.1 -> 3.0.6 candidate): the
# control centre showed plain text because pacman could not install
# python-textual (the VM's package list older than the mirrors: a 404 for
# every file), and its repair printed "the VM's Vulkan driver did not build"
# though it never tried.
#   src/tests/upgrade-path.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- the control centre's Textual: OmacVM's own copy, never pacman ----
# control/guest/install.sh's textual(), run here with a pacman whose every
# download is a 404 (as on the mini) and that writes down each call.
mkdir -p "$T/bin" "$T/home"
# Textual 8.2.8's set needs Python 3.10 or newer (the VM has 3.14; macOS's own is 3.9).
PY=""
for p in python3 /opt/homebrew/bin/python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
  command -v "$p" >/dev/null && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null &&
    { PY=$(command -v "$p"); break; }
done
[[ -n $PY ]] || { echo "upgrade-path: no Python 3.10 or newer here"; exit 1; }
ln -s "$PY" "$T/bin/python3"
cat > "$T/bin/pacman" <<EOF
#!/bin/bash
echo "pacman \$*" >> "$T/pacman-calls"
case \$1 in
  -T) shift; printf '%s\n' "\$@"; exit 127 ;;
  -Q*) exit 1 ;;
  -Sl|-Si) exit 0 ;;
  -S) [[ \$2 == --print ]] && { echo "python-textual 8.2.8-2"; echo "python-platformdirs 4.12.2-1"; exit 0; }
      echo "error: failed retrieving file 'python-platformdirs-4.12.2-1-any.pkg.tar.zst' from mirror : The requested URL returned error: 404" >&2
      exit 1 ;;
esac
exit 1
EOF
chmod +x "$T/bin/pacman"
fn=$(awk '/^textual\(\) \{/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/control/guest/install.sh")
[[ $fn == *textual* ]] || { echo "FAIL install.sh textual() not found"; exit 1; }
tx() {
  ( cd "$R/src/control/guest" || exit 9
    U=$(id -un); H=$T/home
    sudo() { [[ $1 == -u ]] && shift 2; "$@"; }
    export PATH="$T/bin:$PATH" OMACVM_PKG_LOG=$T/pkg.log
    unset XDG_CACHE_HOME OMACVM_VENDOR_DIR
    eval "$fn"
    textual )
}
out=$(tx 2>&1); rc=$?
expect "Textual ready with a stale package list" "0" "$rc"
expect "  nothing said" "" "$out"
expect "  unpacked in the user's cache" yes "$(compgen -G "$T/home/.cache/omacvm/python/*/.omacvm-complete" >/dev/null && echo yes)"
expect "  pacman not asked" "" "$(cat "$T/pacman-calls" 2>/dev/null)"
expect "  it loads from there" 8.2.8 "$("$PY" -I -c 'import glob, sys; sys.path.insert(0, glob.glob(sys.argv[1])[0]); import textual.app; print(textual.__version__)' \
  "$T/home/.cache/omacvm/python/*" 2>&1)"
# A copy that is not as shipped: one line why (not fatal: install.sh goes on with `|| true`).
cp -R "$R/src/control" "$T/control"; mkdir -p "$T/guest"; cp "$R/src/guest/pkg-add" "$T/guest/"
w=$(ls "$T/control/vendor/"rich-*.whl); head -c 1000 "$w" > "$w.cut"; mv "$w.cut" "$w"
rm -rf "$T/home/.cache"
out=$( cd "$T/control/guest" && U=$(id -un) && H=$T/home && sudo() { [[ $1 == -u ]] && shift 2; "$@"; } &&
       export PATH="$T/bin:$PATH" && unset XDG_CACHE_HOME OMACVM_VENDOR_DIR && eval "$fn" && textual 2>&1 ); rc=$?
expect "a damaged copy: status 1" 1 "$rc"
expect "  says which file" yes "$( [[ $out == *"Textual is not ready"*"rich-15.0.0-py3-none-any.whl is not as shipped"* ]] && echo yes)"
# check.sh's line: OmacVM's copy, not pacman's package.
grep -q 'python3 -I /usr/local/share/omacvm/control/omacvm_cc/vendor.py --check' "$R/src/guest/check.sh" ||
  { echo "FAIL check.sh checks OmacVM's copy of Textual"; fail=1; }
grep -q 'pacman -Q python-textual' "$R/src/guest/check.sh" && { echo "FAIL check.sh still asks pacman for Textual"; fail=1; }

# ---- check.sh: a feature whose packages pacman could not install names them and the way out ----
# (a 2.9.1 VM without dkms after its update: camera and Chromium video said "omacvm apply", which
# hits the same 404s again; a system update is what helps)
fn2=$(awk '/^missing_pkgs\(\) \{/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
[[ $fn2 == *missing_pkgs* ]] || { echo "FAIL check.sh missing_pkgs() not found"; exit 1; }
mkdir -p "$T/bin2"; printf '#!/bin/bash\nexit 0\n' > "$T/bin2/pacman"; chmod +x "$T/bin2/pacman"
mp() ( PATH="$1:$PATH"; shift; eval "$fn2"; missing_pkgs "$@" )
expect "packages missing: named, with the way out" \
  "dkms v4l2loopback-dkms not installed (an old package list?): update the system with omarchy update, then r on this row (omacvm apply)" \
  "$(mp "$T/bin" dkms v4l2loopback-dkms)"
expect "packages there: nothing" "" "$(mp "$T/bin2" dkms make gcc)"
for w in 'campkg=$(missing_pkgs dkms v4l2loopback-dkms)' 'vpkg=$(missing_pkgs dkms make gcc)'; do
  grep -qF "$w" "$R/src/guest/check.sh" || { echo "FAIL check.sh: $w"; fail=1; }
done

# ---- apply.sh: "the Vulkan driver did not build" only when it was built ----
block=$(awk '/^  if gssh "\$IP" "\/usr\/local\/share\/omacvm\/app\/guest\/venus\/vulkan-virtio.sh --ready"/ {on = 1}
             on {print} on && /^  fi$/ {exit}' "$R/src/cmd/apply.sh")
[[ $block == *venus-ready* ]] || { echo "FAIL apply.sh venus-ready block not found"; exit 1; }
source "$R/src/lib/graphics.sh"
d=$T/vm; mkdir -p "$d"
vk() {   # ONLY READY(0|1) -> what apply says
  ( SAID=""; IP=ip VM=Omarchy GRAPHICS=vulkan ONLY=$1
    gssh() { return "$READY"; }; READY=$2
    info() { SAID+="[$*]"; }
    eval "$block"; echo "$SAID" )
}
expect "repair of the control centre: no 'did not build'" \
  "[Graphics: Vulkan waits for the VM's driver, which this run does not build: OmacVM in the VM: r on Graphics, or omacvm graphics --vm \"Omarchy\" vulkan]" \
  "$(vk control-centre 1)"
expect "whole VM side, no driver: did not build, and how" \
  "[Graphics: the VM's Vulkan driver did not build (see above): the VM runs on OpenGL until it is built (OmacVM in the VM: r on Graphics, or omacvm graphics --vm \"Omarchy\" vulkan)]" \
  "$(vk "" 1)"
expect "driver there: nothing said, venus-ready" "|yes" "$(vk "" 0)|$([[ -e $d/venus-ready ]] && echo yes)"
# The words for it everywhere (app, omacvm, control centre): no "next apply"
# (it means nothing to someone with only the app).
expect "waiting words" "driver not built yet: runs on OpenGL until it is built (OmacVM in the VM: r on Graphics)" "$GRAPHICS_WAITING_FOR_DRIVER"
for f in app/app/Sources/OmacVM/Graphics.swift src/control/omacvm_cc/state.py src/lib/graphics.sh docs/routes/app.md; do
  grep -q "until the next apply" "$R/$f" && { echo "FAIL $f still says 'until the next apply'"; fail=1; }
done

(( fail )) && { echo "upgrade-path: FAILED"; exit 1; }
echo "upgrade-path: all passed"
