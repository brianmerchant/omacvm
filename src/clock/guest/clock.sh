#!/bin/bash
# Omarchy's bar clock like the Mac's menu bar: at the far right, in the Mac's
# format (from ../mac-clock.swift). Run as root inside the VM:
#   clock.sh USER on FORMAT    move it there; the clock as it was is kept
#   clock.sh USER off          put that clock back where it was
# Edits ~/.config/omarchy/shell.json in one step (Omarchy's shell reloads it).
set -euo pipefail
U=${1:?usage: clock.sh USER on FORMAT | off}; MODE=${2:?on or off}
H=$(getent passwd "$U" | cut -d: -f6)
C=$H/.config/omarchy/shell.json
KEEP=$H/.config/omacvm/clock-before.json
# Off: a clock queued for the next login (omacvm-plugins) is not set either.
[[ $MODE != off ]] || rm -f "$H/.local/state/omacvm/pending-clock"
if [[ ! -f $C ]]; then
  # Fresh build, nobody logged in yet: omacvm-plugins sets it at the next login.
  if [[ $MODE == on ]]; then
    S=$H/.local/state/omacvm
    install -d -o "$U" -g "$U" "$S"
    printf '%s' "${3:?format}" > "$S/pending-clock"; chown "$U:$U" "$S/pending-clock"
    install -m755 "$(dirname "$0")/../../lib/omacvm-plugins" /usr/local/bin/omacvm-plugins
    install -m644 "$(dirname "$0")/../../lib/omacvm-plugins.service" /etc/systemd/user/omacvm-plugins.service
    systemctl --global enable omacvm-plugins.service >/dev/null 2>&1 || true
    echo "clock: set at the next login"
  fi
  exit 0
fi

write() {   # jq program and args; result replaces shell.json in one step, if it changes
  local tmp
  tmp=$(mktemp "$C.XXXXXX")
  jq "$@" "$C" > "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$C"; then rm -f "$tmp"; return 0; fi
  chown "$U:$U" "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$C"
}

case $MODE in
  on)
    FMT=${3:?format}
    if [[ ! -f $KEEP ]]; then
      install -d -o "$U" -g "$U" "$H/.config/omacvm"
      jq '[.bar.layout | to_entries[] | .key as $s | .value | to_entries[]
           | select(.value.id == "omarchy.clock") | {section: $s, index: .key, entry: .value}][0] // {}' "$C" > "$KEEP"
      chown "$U:$U" "$KEEP"
    fi
    write --arg f "$FMT" '
      ([.bar.layout[][] | select(.id == "omarchy.clock")][0] // {id: "omarchy.clock"}) as $c
      | .bar.layout |= map_values(map(select(.id != "omarchy.clock")))
      | .bar.layout.right += [$c + {format: $f}]'
    echo "clock: far right, $FMT" ;;
  off)
    [[ -s $KEEP ]] || exit 0
    if jq -e '.entry' "$KEEP" >/dev/null; then
      write --slurpfile k "$KEEP" '
        $k[0] as $k
        | .bar.layout |= map_values(map(select(.id != "omarchy.clock")))
        | .bar.layout[$k.section] |= (.[:$k.index] + [$k.entry] + .[$k.index:])'
    fi
    rm -f "$KEEP"
    echo "clock: back as it was" ;;
  *) echo "clock.sh: on or off" >&2; exit 2 ;;
esac
