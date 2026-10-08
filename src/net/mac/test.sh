#!/bin/bash
# omacvm-netd's offline tests: it builds without warnings, and its time limits
# on vmnet, back-off, bridge check and failure handling hold, and its VPN NAT
# makes the right rules from made-up interfaces and sharing rules, and touches
# nothing else (test-netd.c, with vmnet and pfctl replaced); install.sh
# --status and the team requirement for release and test builds' QEMU
# (OMACVM_TEST_DEVID_SIGN: a Developer ID Application identity for the
# signed part, skipped without it). No root, no VM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FW=(-framework vmnet -framework Security -framework CoreFoundation -lbsm)
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -o "$T/omacvm-netd" "$HERE/omacvm-netd.c" "${FW[@]}"
echo "ok   omacvm-netd builds without warnings"
p=$("$T/omacvm-netd" --protocol); [[ $p == "$(sed -n 's/^#define NETD_PROTOCOL  *\([0-9]*\).*/\1/p' "$HERE/omacvm-netd.c")" ]] &&
  echo "ok   omacvm-netd --protocol says $p, no root needed" || { echo "FAIL omacvm-netd --protocol: '$p'"; exit 1; }
# A pfctl stand-in: says what it got (arguments, stdin, open descriptors,
# environment); "fail" exits 1, "hang" never ends.
cat > "$T/pfctl" <<'SH'
#!/bin/bash
echo "args: $*"
printf 'in: %s\n' "$(cat)"
fds=""; for ((n = 0; n < 255; n++)); do [[ -e /dev/fd/$n ]] && fds+=" $n"; done   # 255: bash's own
echo "fds:$fds"
echo "env: $(env | grep -v '^_=\|^PWD=\|^SHLVL=\|^OLDPWD=' | sort -r | tr '\n' ' ' | sed 's/ $//')"
[[ $1 == fail ]] && exit 1
[[ $1 == hang ]] && exec sleep 60
exit 0
SH
chmod +x "$T/pfctl"
xcrun clang -O1 -g -Wall -Wno-unused-function -fsanitize=address,undefined -mmacosx-version-min=14.0 \
  -DPFCTL="\"$T/pfctl\"" -o "$T/test-netd" "$HERE/test-netd.c" "${FW[@]}"
# A user's process named like macOS's vmnet service (the daemon must not watch it).
echo '#include <unistd.h>
int main(void) { sleep(120); return 0; }' | xcrun clang -x c -o "$T/InternetSharing" -
"$T/InternetSharing" & FAKE=$!; disown "$FAKE"
trap 'kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT
NETD_STATE=$T/state NETD_FAKE_SHARING=$FAKE "$T/test-netd" 2>"$T/log" || { cat "$T/log" >&2; exit 1; }

# The app's button: install.sh's root script and its arguments reach /bin/sh
# through osascript unchanged (here without the password dialog).
eval "$(sed -n '/^shq() /p; /^root_cmd() /p' "$HERE/install.sh")"
args=("$T/args" "it's" $'two\nlines' '$(id) `id` "q" \\ ;&|' "")
cmd=$(root_cmd 'f=$1; shift; printf "[%s]\n" "$@" > "$f"' _ "${args[@]}")
/usr/bin/osascript - "$cmd" <<'AS' >/dev/null
on run argv
  do shell script (item 1 of argv)
end run
AS
[[ $(cat "$T/args") == "$(printf '[%s]\n' "${args[@]:1}")" ]] && echo "ok   password dialog path: the root script's arguments arrive unchanged" ||
  { echo "FAIL password dialog path: got"; cat "$T/args"; exit 1; }

# --status after an app update: an installed daemon of the same protocol (an
# older build too, also one from before --protocol) serves the new app as it
# is; another protocol, an unknown old build or another app's requirement
# says "old" (the app offers Update...). Made-up daemons and plists in a
# folder of their own (OMACVM_NETD_TEST_ROOT), launchctl stood in for.
S=$(mktemp -d /tmp/netd.XXXXXX)   # short: a socket's path has at most 103 bytes
trap 'kill "$FAKE" 2>/dev/null; rm -rf "$T" "$S"' EXIT
mkdir -p "$S/root/Library/PrivilegedHelperTools" "$S/root/Library/LaunchDaemons" "$S/root/var/run" "$S/bin"
printf '#!/bin/bash\n[[ $1 == print ]]\n' > "$S/bin/launchctl"; chmod +x "$S/bin/launchctl"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$S/root/var/run/org.omacvm.netd.sock"
APP=$S/OmacVM.app; mkdir -p "$APP/Contents/Resources/runtime/bin"
cp /usr/bin/true "$APP/Contents/Resources/runtime/bin/OmacVM"   # Apple-signed: a cdhash to require
QREQ="cdhash H\"$(codesign -dvvv "$APP/Contents/Resources/runtime/bin/OmacVM" 2>&1 | sed -n 's/^CDHash=//p' | head -1)\""
NOW=$(shasum -a 256 "$HERE/omacvm-netd.c" | cut -c1-16)
PROTO=$(sed -n 's/^#define NETD_PROTOCOL  *\([0-9]*\).*/\1/p' "$HERE/omacvm-netd.c")
daemon() {   # VERSION [PROTOCOL]: a daemon that answers as that build (no PROTOCOL: from before --protocol)
  printf '#!/bin/bash\ncase $1 in --version) echo %s ;; --protocol) [[ -n "%s" ]] || { echo usage >&2; exit 2; }; echo %s ;; *) exit 2 ;; esac\n' \
    "$1" "${2:-}" "${2:-}" > "$S/root/Library/PrivilegedHelperTools/org.omacvm.netd"
  chmod +x "$S/root/Library/PrivilegedHelperTools/org.omacvm.netd"
}
plist() {   # REQUIREMENT UID
  python3 -c 'import plistlib,sys; plistlib.dump({"ProgramArguments": ["/Library/PrivilegedHelperTools/org.omacvm.netd",
    "--requirement", sys.argv[2], "--user", sys.argv[3]]}, open(sys.argv[1], "wb"))' \
    "$S/root/Library/LaunchDaemons/org.omacvm.netd.plist" "$1" "$2"
}
status_is() {   # WANT WHAT [APP]
  local got
  got=$(PATH="$S/bin:$PATH" OMACVM_NETD_TEST_ROOT=$S/root "$HERE/install.sh" --status --app "${3:-$APP}" | head -1)
  [[ $got == "$1" ]] && echo "ok   status $1: $2" || { echo "FAIL status: $2: got '$got', want '$1'"; exit 1; }
}
plist "$QREQ" "$(id -u)"
daemon "$NOW" "$PROTO";                 status_is ok "this source's build"
daemon 0123456789abcdef "$PROTO";       status_is ok "another build of the same protocol (no new install after an app update)"
daemon 47acb85b894557f3;                status_is old "3.0.0's build (its VPN NAT does not follow a route change): installed again"
daemon f141e093f466a64a;                status_is ok "3.0.1-3.0.3's build, from before --protocol (protocol 1)"
daemon 35049a2bfcceb419;                status_is old "2.9's build (no VPN NAT): installed again"
daemon 0123456789abcdef "$((PROTO + 1))"; status_is old "another protocol"
daemon 0123456789abcdef;                status_is old "an unknown build without --protocol"
daemon "$NOW" "$PROTO"
plist 'cdhash H"0000000000000000000000000000000000000000"' "$(id -u)"; status_is old "installed for another app's QEMU"
plist "$QREQ" 4242;                     status_is missing "installed for another Mac user only"
plist "$QREQ" "$(id -u)"
printf '#!/bin/bash\nexit 1\n' > "$S/bin/launchctl"; status_is down "installed, launchd does not run it"
printf '#!/bin/bash\n[[ $1 == print ]]\n' > "$S/bin/launchctl"

# Team trust: a release app's QEMU requirement keeps its text (installed
# daemons stay "ok"); a test build's (OmacVM Test.app) takes both QEMU
# identifiers of the same team, and only those.
eval "$(sed -n '/^devid() /p; /^devid_of() /,/^}/p; /^QEMU_ID=/p; /^TEST_QEMU_ID=/p; /^devid_qemus() /p; /^signer_req() /,/^}/p' "$HERE/install.sh")"
DEVID='certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "722686Y34B"'
PROD_REQ="anchor apple generic and identifier \"org.omacvm.app.qemu\" and $DEVID"
BOTH_REQ="anchor apple generic and (identifier \"org.omacvm.app.qemu\" or identifier \"org.omacvm.app.test.qemu\") and $DEVID"
want_req() {   # WANT GOT WHAT
  [[ $2 == "$1" ]] && echo "ok   $3" || { echo "FAIL $3: got '$2', want '$1'"; exit 1; }
}
want_req "$PROD_REQ" "$(signer_req "722686Y34B org.omacvm.app.qemu")" "a release app's QEMU: the team requirement as before"
want_req "$BOTH_REQ" "$(signer_req "722686Y34B org.omacvm.app.test.qemu")" "a test build's QEMU: its team, release and test QEMU identifiers"
csreq -r="$BOTH_REQ" -t >/dev/null 2>&1 && echo "ok   ... a valid code requirement" || { echo "FAIL not a code requirement: $BOTH_REQ"; exit 1; }

# With a Developer ID (OMACVM_TEST_DEVID_SIGN, as release-keys.sh): QEMUs of
# that team, signed as the release's, the test identity's or another
# identifier, against the daemon's requirement (as it checks callers) and
# --status.
if [[ -n ${OMACVM_TEST_DEVID_SIGN:-} ]]; then
  echo 'int main(void) { return 0; }' | xcrun clang -x c -o "$S/q" -
  for id in org.omacvm.app.qemu org.omacvm.app.test.qemu org.omacvm.app.other.qemu; do
    mkdir -p "$S/$id.app/Contents/Resources/runtime/bin"
    cp "$S/q" "$S/$id.app/Contents/Resources/runtime/bin/OmacVM"
    codesign --force --timestamp=none --sign "$OMACVM_TEST_DEVID_SIGN" --identifier "$id" "$S/$id.app/Contents/Resources/runtime/bin/OmacVM" 2>/dev/null
  done
  REL=$S/org.omacvm.app.qemu.app TST=$S/org.omacvm.app.test.qemu.app OTH=$S/org.omacvm.app.other.qemu.app
  TEAM=$(codesign -dv "$REL/Contents/Resources/runtime/bin/OmacVM" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  takes() { codesign --verify -R="$1" "$2/Contents/Resources/runtime/bin/OmacVM" 2>/dev/null && echo yes || echo no; }   # REQ APP
  want_req "yes yes no" "$(takes "$(devid_qemus "$TEAM")" "$REL") $(takes "$(devid_qemus "$TEAM")" "$TST") $(takes "$(devid_qemus "$TEAM")" "$OTH")" \
    "a test build's team requirement takes the team's release and test QEMUs, not another identifier"
  want_req "no no" "$(takes "$(devid_qemus 0000000000)" "$TST") $(takes "$(devid "$TEAM" org.omacvm.app.qemu)" "$TST")" \
    "... another team's does not take the test QEMU, nor does a release app's"
  plist "$(devid "$TEAM" org.omacvm.app.qemu)" "$(id -u)"
  status_is ok "installed for a release app's team: the release app" "$REL"
  status_is old "... a test build of that team (it does not take its QEMU: installed again, once)" "$TST"
  plist "$(devid_qemus "$TEAM")" "$(id -u)"
  status_is ok "installed for a test build's team: the next test build" "$TST"
  status_is ok "... and the release app of that team" "$REL"
  status_is old "... not another identifier of that team" "$OTH"
  plist "$(devid_qemus 0000000000)" "$(id -u)"
  status_is old "installed for another team's test builds" "$TST"
else
  echo "skip the Developer ID QEMU checks (set OMACVM_TEST_DEVID_SIGN to a Developer ID Application identity)"
fi

# A job a VM asked for (OMACVM_ADMIN_PROMPT=none) never becomes root, not even
# with a sudo that needs no password: exit 3, sudo never asked.
printf '#!/bin/bash\necho "$*" >> %q\nexit 0\n' "$S/sudo-called" > "$S/bin/sudo"; chmod +x "$S/bin/sudo"
printf '#!/bin/bash\n[[ $1 == print ]]\n' > "$S/bin/launchctl"
rc=0; PATH="$S/bin:$PATH" OMACVM_ADMIN_PROMPT=none OMACVM_NETD_TEST_ROOT=$S/root "$HERE/install.sh" --remove 2>"$S/err" || rc=$?
if [[ $rc == 3 && ! -e $S/sudo-called && -e $S/root/Library/LaunchDaemons/org.omacvm.netd.plist ]] && grep -q "on the Mac" "$S/err"; then
  echo "ok   a VM's job (OMACVM_ADMIN_PROMPT=none): exit 3, no sudo, nothing removed"
else echo "FAIL a VM's job became root or did not stop: rc=$rc sudo: $(cat "$S/sudo-called" 2>/dev/null) err: $(cat "$S/err")"; exit 1; fi
