#!/bin/bash
# Touch ID's guest side (ADR 0041) without a VM: the PAM client against a
# fake Bridge (tests/touchid/fake-bridge.py) for every answer it can get, and
# touchid.sh putting its PAM lines in and taking them out again.
#   src/tests/touchid-client.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/bridge/guest
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1: want '$2', got '$3'"; fi; }
T=$(mktemp -d); FPID=
trap 'if [[ -n $FPID ]]; then kill "$FPID" 2>/dev/null; fi; rm -rf "$T"' EXIT

mkdir -p "$T/etc" "$T/run" "$T/proc/$$" "$T/bridge"
openssl rand -hex 32 > "$T/bridge/token"; openssl rand -hex 32 > "$T/bridge/key"
cp "$T/bridge/token" "$T/etc/touchid-token"; cp "$T/bridge/key" "$T/etc/touchid-key"
chmod 600 "$T/etc/"*
printf 'sudo\0pacman\0-Syu\0' > "$T/proc/$$/cmdline"
python3 "$R/src/tests/touchid/fake-bridge.py" "$T/bridge" & FPID=$!
for _ in $(seq 50); do [[ -s $T/bridge/port ]] && break; sleep 0.1; done
[[ -s $T/bridge/port ]] || { echo "FAIL the fake Bridge did not start"; exit 1; }

export OMACVM_TOUCHID_TEST=1 OMACVM_TOUCHID_ETC=$T/etc OMACVM_TOUCHID_RUN=$T/run OMACVM_TOUCHID_PROC=$T/proc
export OMACVM_TOUCHID_HOST=127.0.0.1 OMACVM_TOUCHID_PORT=$(cat "$T/bridge/port") OMACVM_TOUCHID_LOCAL=yes
export PAM_TYPE=auth PAM_USER=vincent PAM_SERVICE=sudo
# The client's parent is this shell ($$): its "sudo" command line is the fake one above.
run() {   # MODE -> rc in $rc, output in $T/out, the request's body in $last
  echo "$1" > "$T/bridge/mode"; : > "$T/bridge/requests"
  python3 "$G/omacvm-touchid" > "$T/out" 2>&1; rc=$?
  last=$(tail -1 "$T/bridge/requests" | python3 -c 'import json, sys; l = sys.stdin.read(); print(json.loads(l)["body"] if l else "")')
}

run yes; expect "yes: let in" 0 "$rc"
expect "asks on the screen" "Touch ID on your Mac, or wait for the password prompt" "$(head -1 "$T/out")"
expect "sudo: kind and command" '{"user":"vincent","kind":"sudo","detail":"pacman -Syu"}' "$last"
run no-cancelled; expect "cancelled: password" 1 "$rc"
expect "cancelled: nothing more said" 1 "$(wc -l < "$T/out" | tr -d ' ')"
run no-not-front; expect "VM not in front: password" 1 "$rc"
expect "VM not in front: said" "Touch ID not available (VM not in front), use your password" "$(tail -1 "$T/out")"
run no-locked; expect "Mac locked: said" "Touch ID not available (Mac locked), use your password" "$(tail -1 "$T/out")"
run off; expect "off on the Mac: password" 1 "$rc"
expect "off on the Mac: said" "Touch ID not available (Touch ID off), use your password" "$(tail -1 "$T/out")"
run unsigned; expect "unsigned yes: password" 1 "$rc"
run other-key; expect "yes signed with another key: password" 1 "$rc"
run other-nonce; expect "yes for another request: password" 1 "$rc"
run wrong-proof; expect "Bridge without the token: password" 1 "$rc"
expect "... and the token never sent" 0 "$(wc -l < "$T/bridge/requests" | tr -d ' ')"
PAM_SERVICE=login run yes; expect "another PAM service: password" 1 "$rc"
expect "... without asking" "" "$last"
OMACVM_TOUCHID_LOCAL=no run yes; expect "over SSH: password" 1 "$rc"
expect "... without asking" "" "$last"
PAM_USER='Bad User' run yes; expect "odd user name: password" 1 "$rc"
mv "$T/etc/touchid-key" "$T/key.off"; run yes; expect "no key (off in the VM): password" 1 "$rc"; mv "$T/key.off" "$T/etc/touchid-key"

# polkit: the rule's note names the action; 1Password gets its own text.
export PAM_SERVICE=polkit-1
python3 "$G/omacvm-touchid" --note vincent com.1password.1Password.unlock; expect "the rule's note" 0 "$?"
run yes; expect "1Password: kind" '{"user":"vincent","kind":"1password"}' "$last"
python3 "$G/omacvm-touchid" --note vincent org.freedesktop.systemd1.manage-units
run yes; expect "polkit: the action" '{"user":"vincent","kind":"polkit","action":"org.freedesktop.systemd1.manage-units"}' "$last"
echo "$(( $(date +%s) - 30 )) com.1password.1Password.unlock" > "$T/run/vincent"
run yes; expect "an old note: no action" '{"user":"vincent","kind":"polkit"}' "$last"
python3 "$G/omacvm-touchid" --note vincent 'bad action;rm'; expect "a bad note is refused" 1 "$?"
python3 "$G/omacvm-touchid" --note ../x a.b; expect "a bad user in a note is refused" 1 "$?"

# The Bridge down: the password prompt within 2 s.
kill "$FPID"; wait "$FPID" 2>/dev/null; FPID=
s=$(python3 -c 'import time; print(time.time())')
run yes
took=$(python3 -c "import time; print(int((time.time() - $s) * 1000))")
expect "Bridge down: password" 1 "$rc"
if (( took < 2000 )); then ok "Bridge down: answered in ${took} ms"; else bad "Bridge down: took ${took} ms"; fi

# touchid.sh: the PAM lines in before the first auth line, once; out again, files as before.
P=$T/root/etc/pam.d; mkdir -p "$P"
printf '#%%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\nsession\t\tinclude\t\tsystem-auth\n' > "$P/sudo"
printf '#%%PAM-1.0\n\nauth       include      system-auth\naccount    include      system-auth\npassword   include      system-auth\nsession    include      system-auth\n' > "$P/polkit-1"
printf '#%%PAM-1.0\nauth include system-auth\n' > "$P/login"
cp -R "$P" "$T/pam.orig"
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on && OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" on
expect "on: sudo's first auth line is ours" "auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid" \
  "$(grep -m1 '^auth' "$P/sudo")"
expect "on: polkit-1's too" "auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid" \
  "$(grep -m1 '^auth' "$P/polkit-1")"
expect "on twice: one line" 1 "$(grep -c pam_exec "$P/sudo")"
expect "login untouched" "" "$(diff "$T/pam.orig/login" "$P/login")"
expect "the client and the rule installed" yes "$([[ -x $T/root/usr/lib/omacvm/omacvm-touchid && -f $T/root/etc/polkit-1/rules.d/49-omacvm-touchid.rules ]] && echo yes)"
mkdir -p "$T/root/etc/omacvm"; touch "$T/root/etc/omacvm/touchid-key" "$T/root/etc/omacvm/touchid-token"
OMACVM_TOUCHID_ROOT=$T/root "$G/touchid.sh" off
expect "off: sudo as before" "" "$(diff "$T/pam.orig/sudo" "$P/sudo")"
expect "off: polkit-1 as before" "" "$(diff "$T/pam.orig/polkit-1" "$P/polkit-1")"
expect "off: client, rule and keys gone" "" "$(ls "$T/root/usr/lib/omacvm" "$T/root/etc/polkit-1/rules.d" "$T/root/etc/omacvm" 2>/dev/null | grep -v ':$' | grep .)"
exit $fail
