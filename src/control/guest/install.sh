#!/bin/bash
# The control centre in the VM (feature control-centre). Run as root by
# ../../guest/install.sh:
#   control/guest/install.sh <desktop-user> on|off [vm-type]
# On: Textual (pacman), /usr/local/bin/omacvm, the root check socket (the
# guest checks for the control centre: a fixed command, nothing read from the
# caller), the app launcher entry, an "OmacVM" row in the Omarchy menu, the
# OmacVM item in the bar, and the update notice (a user timer). OmacVM.app:
# the desktop user may open the app's control port. Off: all of it goes
# again. Idempotent. The menu, the bar and the launcher run `omacvm --window`.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> on|off [vm-type]}; WANT=${2:?on|off}; TYPE=${3:-}
PORT_RULE=/etc/udev/rules.d/70-omacvm-control.rules
H=$(getent passwd "$U" | cut -d: -f6)
SHARE=/usr/local/share/omacvm
MENU=$H/.config/omarchy/extensions/omarchy-menu.jsonc
user_ctl() { systemctl --user -M "$U@" "$@"; }
as_user() {
  sudo -u "$U" env HOME="$H" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" \
    bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap 2>/dev/null; exec "$@"' _ "$@"
}

# The menu row: two lines (a marker comment, then the row) in the user's own
# extension file, right after its opening brace; the rest of the file stays
# theirs. Omarchy strips only whole-line comments and trailing commas.
menu_line() {
  [[ -f $MENU || $1 == on ]] || return 0
  install -d -o "$U" -g "$U" "$(dirname "$MENU")"
  python3 - "$MENU" "$1" <<'PY'
import os, sys
path, want = sys.argv[1], sys.argv[2]
mark = "  // OmacVM control centre, the next line (on the Mac: omacvm disable control-centre)"
row = ('  "omacvm": {"icon":"\U000f0633","label":"OmacVM","description":"features, updates, report a problem",'
       '"action":"omarchy-launch-or-focus-tui omacvm --window"},')
old = open(path, encoding="utf-8").read() if os.path.exists(path) else "{\n}\n"
out, skip = [], False
for line in old.split("\n"):
    if skip:
        skip = False
    elif line.strip() == mark.strip():
        skip = True
    else:
        out.append(line)
if want == "on":
    at = next((i for i, l in enumerate(out) if l.strip() == "{"), None)
    if at is None:
        sys.exit("  the Omarchy menu file has no line with only '{': add an OmacVM row yourself (omarchy-launch-or-focus-tui omacvm --window)")
    out[at + 1:at + 1] = [mark, row]
new = "\n".join(out)
if new != old:
    tmp = path + ".omacvm"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new)
    os.replace(tmp, path)
PY
  chown "$U:$U" "$MENU"
}

if [[ $WANT == on ]]; then
  pacman -S --needed --noconfirm python python-textual >/dev/null 2>&1 ||
    echo "  python-textual not installed (no network?): omacvm shows its plain text table until the next omacvm apply"
  ln -sfn "$SHARE/control/omacvm" /usr/local/bin/omacvm
  # The guest checks run as root (they read services, the firewall, other
  # users' processes); the desktop user may ask for them through this socket.
  sed "s/@USER@/$U/g" omacvm-check.socket > /etc/systemd/system/omacvm-check.socket
  sed "s/@USER@/$U/g" omacvm-check@.service > /etc/systemd/system/omacvm-check@.service
  systemctl daemon-reload
  systemctl enable omacvm-check.socket >/dev/null 2>&1
  systemctl restart omacvm-check.socket
  install -Dm644 omacvm.desktop /usr/local/share/applications/omacvm.desktop
  # OmacVM.app: the requests go through the app's control port, which only
  # the desktop user may open.
  if [[ $TYPE == app ]]; then
    printf 'SUBSYSTEM=="virtio-ports", ATTR{name}=="org.omacvm.control", OWNER="%s", MODE="0600"\n' "$U" > "$PORT_RULE"
    udevadm control --reload 2>/dev/null; udevadm trigger --subsystem-match=virtio-ports 2>/dev/null || true
  fi
  install -m644 omacvm-notify.service omacvm-notify.timer /etc/systemd/user/
  user_ctl daemon-reload 2>/dev/null || true
  user_ctl enable --now omacvm-notify.timer >/dev/null 2>&1 ||
    { install -d -o "$U" -g "$U" "$H/.config/systemd/user/timers.target.wants"
      ln -sf /etc/systemd/user/omacvm-notify.timer "$H/.config/systemd/user/timers.target.wants/"; }
  menu_line on
  ../../lib/install-plugin.sh "$U" ../plugins/omacvm.control
else
  [[ -L /usr/local/bin/omacvm ]] && rm -f /usr/local/bin/omacvm
  systemctl disable --now omacvm-check.socket >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/omacvm-check.socket /etc/systemd/system/omacvm-check@.service
  systemctl daemon-reload
  rm -f /usr/local/share/applications/omacvm.desktop
  if [[ -f $PORT_RULE ]]; then rm -f "$PORT_RULE"; udevadm control --reload 2>/dev/null || true; fi
  user_ctl disable --now omacvm-notify.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/user/omacvm-notify.service /etc/systemd/user/omacvm-notify.timer "$H/.config/systemd/user/timers.target.wants/omacvm-notify.timer"
  menu_line off
  if [[ -d $H/.config/omarchy/plugins/omacvm.control ]]; then
    # Without a running shell, out of its bar settings by hand (it reads them when it starts).
    C=$H/.config/omarchy/shell.json
    if ! as_user omarchy plugin disable omacvm.control >/dev/null 2>&1 && [[ -f $C ]]; then
      tmp=$(mktemp "$C.XXXXXX")
      if jq '(.bar.layout[]?) |= map(select(.id != "omacvm.control")) | (.plugins // empty) |= map(select(.id != "omacvm.control"))' "$C" > "$tmp"; then
        chmod --reference="$C" "$tmp"; chown "$U:$U" "$tmp"; mv -f "$tmp" "$C"
      else rm -f "$tmp"; fi
    fi
    rm -rf "$H/.config/omarchy/plugins/omacvm.control"
    sed -i '/^omacvm\.control$/d' "$H/.local/state/omacvm/pending-plugins" 2>/dev/null || true
  fi
  rm -rf "$H/.cache/omacvm"
fi
