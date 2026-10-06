#!/bin/bash
# Touch ID for sudo and polkit (ADR 0041), guest side, as root:
#   touchid.sh on | off
# on: the PAM client, one PAM line at the top of sudo's and polkit-1's auth,
# the polkit rule that names the action, its /run folder. The keys
# (/etc/omacvm/touchid-key, touchid-token) come from omacvm apply.
# off: all of it gone again, the keys too. The password works either way.
# OMACVM_TOUCHID_ROOT: another root folder (tests).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${OMACVM_TOUCHID_ROOT:-}
BIN=$ROOT/usr/lib/omacvm/omacvm-touchid
RULE=$ROOT/etc/polkit-1/rules.d/49-omacvm-touchid.rules
TMPF=$ROOT/etc/tmpfiles.d/omacvm-touchid.conf
PAMD=$ROOT/etc/pam.d
MARK='# omacvm touch-id (ADR 0041): the Mac'"'"'s Touch ID first, the password after'
LINE='auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid'

pam_add() {   # <service>: our two lines before its first auth line
  local f=$PAMD/$1
  [[ -f $f ]] || return 0   # no such service here: nothing to unlock
  grep -qxF "$LINE" "$f" && return 0
  awk -v m="$MARK" -v l="$LINE" '!d && /^[[:space:]]*-?auth[[:space:]]/ { print m; print l; d = 1 } { print } END { if (!d) { print m; print l } }' \
    "$f" > "$f.omacvm-new"
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}
pam_remove() {
  local f=$PAMD/$1
  [[ -f $f ]] && grep -qxF -e "$LINE" -e "$MARK" "$f" || return 0
  grep -vxF -e "$LINE" -e "$MARK" "$f" > "$f.omacvm-new" || true
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}

case ${1:-} in
  on)
    mkdir -p "$(dirname "$BIN")" "$(dirname "$RULE")" "$(dirname "$TMPF")"
    install -m755 "$HERE/omacvm-touchid" "$BIN"
    install -m644 "$HERE/49-omacvm-touchid.rules" "$RULE"
    echo 'd /run/omacvm-touchid 0700 polkitd polkitd -' > "$TMPF"
    [[ -n $ROOT ]] || systemd-tmpfiles --create "$TMPF" 2>/dev/null || true
    for s in sudo polkit-1; do pam_add "$s"; done ;;
  off)
    for s in sudo polkit-1; do pam_remove "$s"; done
    rm -f "$RULE" "$TMPF" "$BIN" "$ROOT/etc/omacvm/touchid-key" "$ROOT/etc/omacvm/touchid-token"
    rm -rf "$ROOT/run/omacvm-touchid" ;;
  *) echo "touchid.sh on|off" >&2; exit 2 ;;
esac
