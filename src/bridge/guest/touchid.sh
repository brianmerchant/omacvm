#!/bin/bash
# Touch ID for sudo and polkit (ADR 0041), guest side, as root:
#   touchid.sh on | off [desktop-user]
# on: the PAM client, one PAM line at the top of the auth of sudo, sudo-i and
# polkit-1, the polkit rule and its note writer, their /run folder. The keys
# (/etc/omacvm/touchid-key, touchid-token) come from omacvm apply. For the
# desktop user: omacvm-touchid-theme and its user units, which send the
# Omarchy theme's colours to the Mac's Touch ID panel.
# off: all of it gone again, the keys too. The password works either way.
# A service with only the vendor's file (/usr/lib/pam.d/polkit-1 since
# polkit 127) gets a copy in /etc/pam.d with our line; off removes the copy.
# polkit 127 starts its helper in a sandbox without network: a drop-in lets
# it (and so the PAM client) reach the Mac's Bridge address, nothing else.
# OMACVM_TOUCHID_ROOT: another root folder (tests).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${OMACVM_TOUCHID_ROOT:-}
BIN=$ROOT/usr/lib/omacvm/omacvm-touchid
NOTE=$ROOT/usr/lib/omacvm/omacvm-touchid-note
RULE=$ROOT/etc/polkit-1/rules.d/00-omacvm-touchid.rules
OLDRULE=$ROOT/etc/polkit-1/rules.d/49-omacvm-touchid.rules
THEME=$ROOT/usr/lib/omacvm/omacvm-touchid-theme
UNITS=$ROOT/etc/systemd/user
U=${2:-}
TMPF=$ROOT/etc/tmpfiles.d/omacvm-touchid.conf
DROPIN=$ROOT/etc/systemd/system/polkit-agent-helper@.service.d/omacvm-touchid.conf
PAMD=$ROOT/etc/pam.d
VENDOR=$ROOT/usr/lib/pam.d
SERVICES="sudo sudo-i polkit-1"
MARK='# omacvm touch-id (ADR 0041): the Mac'"'"'s Touch ID first, the password after'
LINE='auth       sufficient   pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid'

COPY='# omacvm touch-id: a copy of'
pam_add() {   # <service>: our two lines before its first auth line
  local f=$PAMD/$1
  if [[ ! -f $f ]]; then
    [[ -f $VENDOR/$1 ]] || return 0   # no such service here: nothing to unlock
    { echo "$COPY /usr/lib/pam.d/$1 (omacvm disable touch-id removes it)"; cat "$VENDOR/$1"; } > "$f.omacvm-copy"
    chmod 644 "$f.omacvm-copy" && mv -f "$f.omacvm-copy" "$f"
  fi
  grep -qxF "$LINE" "$f" && return 0
  awk -v m="$MARK" -v l="$LINE" '!d && /^[[:space:]]*-?auth[[:space:]]/ { print m; print l; d = 1 } { print } END { if (!d) { print m; print l } }' \
    "$f" > "$f.omacvm-new"
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}
pam_remove() {
  local f=$PAMD/$1
  [[ -f $f ]] || return 0
  if grep -q "^$COPY /usr/lib/pam.d/$1 " "$f"; then rm -f "$f"; return 0; fi   # ours: the vendor's file counts again
  grep -qxF -e "$LINE" -e "$MARK" "$f" || return 0
  grep -vxF -e "$LINE" -e "$MARK" "$f" > "$f.omacvm-new" || true
  chmod 644 "$f.omacvm-new" && mv -f "$f.omacvm-new" "$f"
}

# The theme sender's user units, for the desktop user (only in a real VM).
user_units() {   # on|off
  [[ -n $U && -z $ROOT ]] || return 0
  local uc=(systemctl --user -M "$U@")
  if [[ $1 == on ]]; then
    "${uc[@]}" daemon-reload 2>/dev/null || true
    "${uc[@]}" enable omacvm-touchid-theme.path omacvm-touchid-theme.service >/dev/null 2>&1 || true
    "${uc[@]}" restart omacvm-touchid-theme.path >/dev/null 2>&1 || true
    "${uc[@]}" start --no-block omacvm-touchid-theme.service >/dev/null 2>&1 || true
  else
    "${uc[@]}" disable --now omacvm-touchid-theme.path omacvm-touchid-theme.service >/dev/null 2>&1 || true
  fi
}

case ${1:-} in
  on)
    mkdir -p "$(dirname "$BIN")" "$(dirname "$RULE")" "$(dirname "$TMPF")"
    install -m755 "$HERE/omacvm-touchid" "$BIN"
    install -m755 "$HERE/omacvm-touchid-note" "$NOTE"
    install -m755 "$HERE/omacvm-touchid-theme" "$THEME"
    mkdir -p "$UNITS"
    install -m644 "$HERE/omacvm-touchid-theme.service" "$HERE/omacvm-touchid-theme.path" "$UNITS/"
    install -m644 "$HERE/00-omacvm-touchid.rules" "$RULE"
    rm -f "$OLDRULE"
    echo 'd /run/omacvm-touchid 0700 polkitd polkitd -' > "$TMPF"
    [[ -n $ROOT ]] || systemd-tmpfiles --create "$TMPF" 2>/dev/null || true
    host=$( { sed -n "s/^OMACVM_HOST=['\"]\{0,1\}\([0-9.]*\).*/\1/p" "$ROOT/etc/omacvm/env" 2>/dev/null || true; } | tail -1)
    [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || host=10.211.55.2   # the client's default too
    mkdir -p "$(dirname "$DROPIN")"
    printf '%s\n' "# omacvm touch-id (ADR 0041): polkit's helper may reach the Mac's Bridge ($host), nothing else" \
      '[Service]' 'PrivateNetwork=no' 'RestrictAddressFamilies=AF_UNIX AF_INET' 'IPAddressDeny=any' "IPAddressAllow=$host" > "$DROPIN"
    [[ -n $ROOT ]] || systemctl daemon-reload 2>/dev/null || true
    for s in $SERVICES; do pam_add "$s"; done
    user_units on ;;
  off)
    user_units off
    rm -f "$THEME" "$UNITS/omacvm-touchid-theme.service" "$UNITS/omacvm-touchid-theme.path"
    for s in $SERVICES; do pam_remove "$s"; done
    rm -f "$RULE" "$OLDRULE" "$TMPF" "$BIN" "$NOTE" "$ROOT/etc/omacvm/touchid-key" "$ROOT/etc/omacvm/touchid-token"
    rm -rf "$ROOT/run/omacvm-touchid"
    if [[ -e $DROPIN ]]; then
      rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
      [[ -n $ROOT ]] || systemctl daemon-reload 2>/dev/null || true
    fi ;;
  *) echo "touchid.sh on|off [desktop-user]" >&2; exit 2 ;;
esac
