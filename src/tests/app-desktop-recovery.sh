#!/bin/bash
# OmacVM.app: when the VM's desktop loses its GPU context on the Mac.
# - The app's rules (DesktopRecovery.swift, compiled on its own): Hyprland
#   lost -> the desktop restarts by itself, at most once in 10 minutes, then
#   the app asks; off -> it always asks; the shell (Quickshell) lost -> only
#   the shell restarts, at most once a minute; other apps -> nothing.
# - The VM's omacvm-desktop-recover with stand-ins for systemctl, sudo,
#   hyprctl and notify-send: the note names the apps that closed, the login
#   manager restarts, the new session shows the note once, the shell mode
#   restarts only the shell.
# No VM, no window.
#   src/tests/app-desktop-recovery.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's rules.
cat > "$T/main.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
switch a[1] {
case "action":   // LOST(comma list) ENABLED LAST_DESKTOP_AGO|- LAST_SHELL_AGO|-
  let now = Date()
  let ago = { (s: String) -> Date? in s == "-" ? nil : now.addingTimeInterval(-Double(s)!) }
  let lost = a[2].isEmpty ? [] : a[2].split(separator: ",").map(String.init)
  switch DesktopRecovery.action(lost: lost, enabled: a[3] == "on", lastDesktop: ago(a[4]), lastShell: ago(a[5]), now: now) {
  case .none: print("none")
  case .restartDesktop: print("restart")
  case .ask(let again): print(again ? "ask-again" : "ask")
  case .restartShell: print("shell")
  }
case "reason":   // PRESSURE REFUSED
  print(DesktopRecovery.reason(pressure: a[2], refused: Int(a[3])!))
case "enabled":  // DOMAIN [set true|false]
  let d = UserDefaults(suiteName: a[2])!
  if a.count > 3 { d.set(a[3] == "true", forKey: DesktopRecovery.key) }
  print(DesktopRecovery.enabled(d) ? "on" : "off")
default: exit(2)
}
SWIFT
if ! swiftc -O -o "$T/rules" "$R/app/app/Sources/OmacVM/DesktopRecovery.swift" "$T/main.swift" 2>"$T/swiftc.log"; then
  cat "$T/swiftc.log"; echo "FAIL DesktopRecovery.swift does not compile on its own"; exit 1
fi
r() { "$T/rules" "$@"; }
expect "Hyprland lost: restarts by itself"                  restart   "$(r action Hyprland on - -)"
expect "Hyprland among others: restarts by itself"          restart   "$(r action chromium,Hyprland,quickshell on - -)"
expect "lost again 5 min after a restart: asks"             ask-again "$(r action Hyprland on 300 -)"
expect "lost again 11 min after a restart: restarts"        restart   "$(r action Hyprland on 660 -)"
expect "switched off: asks"                                 ask       "$(r action Hyprland off - -)"
expect "the shell lost: only the shell restarts"            shell     "$(r action quickshell on - -)"
expect "the shell lost again within a minute: nothing"      none      "$(r action quickshell on - 30)"
expect "the shell lost after two minutes: restarts it"      shell     "$(r action quickshell on - 120)"
expect "the shell lost, switched off: nothing"              none      "$(r action quickshell off - -)"
expect "a browser lost: nothing (it is not the desktop)"    none      "$(r action chromium on - -)"
expect "no names: nothing"                                  none      "$(r action '' on - -)"
expect "normal pressure, nothing refused: graphics"         graphics  "$(r reason normal 0)"
expect "refused: memory"                                    memory    "$(r reason normal 3)"
expect "critical pressure: memory"                          memory    "$(r reason critical 0)"
D=org.omacvm.test.desktoprecovery.$$
expect "on unless switched off"                             on        "$(r enabled "$D")"
expect "defaults write ... desktopAutoRestart -bool false"  off       "$(r enabled "$D" false)"
defaults delete "$D" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$D.plist"

# The VM's side, with stand-ins.
S=$T/bin; mkdir -p "$S"
export CALLS=$T/calls
printf '#!/bin/bash\necho "systemctl $*" >> "$CALLS"\n' > "$S/systemctl"
printf '#!/bin/bash\necho "logger $*" >> "$CALLS"\n' > "$S/logger"
# sudo -u USER env ... bash -c '...' _ CMD...: run CMD (the part after "_").
printf '#!/bin/bash\nwhile [[ $# -gt 0 && $1 != _ ]]; do shift; done; shift; "$@"\n' > "$S/sudo"
printf '#!/bin/bash\nshift; "$@"\n' > "$S/timeout"
printf '#!/bin/bash\n[[ $1 == -f ]] && shift; "$@"\n' > "$S/setsid"
printf '#!/bin/bash\necho omarchy-restart-shell >> "$CALLS"\n' > "$S/omarchy-restart-shell"
printf '#!/bin/bash\n[[ $* == "clients -j" ]] && cat "$CLIENTS"\n' > "$S/hyprctl"
printf '#!/bin/bash\n[[ -e $NOTIFY_FAILS ]] && exit 1; printf "%%s|" "notify-send" "$@" >> "$CALLS"; echo >> "$CALLS"\n' > "$S/notify-send"
printf '#!/bin/bash\n[[ $1 == -u ]] && { echo 1000; exit; }; [[ $1 == -gn ]] && { echo staff; exit; }; echo staff\n' > "$S/id"
printf '#!/bin/bash\necho "x:x:1000:1000::$HOME:/bin/bash"\n' > "$S/getent"
printf '#!/bin/bash\n[[ $1 == -d ]] && mkdir -p "${@: -1}"\n' > "$S/install"
printf '#!/bin/bash\n:\n' > "$S/chown"
printf '#!/bin/bash\n:\n' > "$S/sleep"
chmod +x "$S"/*
export PATH="$S:$PATH"
export OMACVM_RECOVER_ENV=$T/env OMACVM_RECOVER_NOTE=$T/run/desktop/restarted CLIENTS=$T/clients NOTIFY_FAILS=$T/notify-fails
printf 'OMACVM_VM_TYPE=app\nOMACVM_USER=tester\n' > "$T/env"
cat > "$CLIENTS" <<'JSON'
[{"class": "chromium", "title": "a"}, {"class": "Alacritty"}, {"class": "chromium"}, {"class": "", "initialClass": "obsidian"}]
JSON
G=$R/src/app/guest/omacvm-desktop-recover
: > "$CALLS"
"$G" desktop memory > /dev/null
expect "desktop: the login manager restarts"     "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
expect "desktop: the note says why"              memory                   "$(sed -n 's/^why=//p' "$T/run/desktop/restarted")"
expect "desktop: the note names the apps once"   "chromium, Alacritty, obsidian" "$(sed -n 's/^apps=//p' "$T/run/desktop/restarted")"
grep -q "closing: chromium, Alacritty, obsidian" "$CALLS" && expect "desktop: logged to the journal" yes yes \
  || expect "desktop: logged to the journal" yes no
: > "$CALLS"
"$G" notify
n=$(grep -c '^notify-send' "$CALLS")
expect "notify: shown once"                      1 "$n"
grep -q "These apps were closed: chromium, Alacritty, obsidian. Anything not saved in them is lost." "$CALLS" \
  && expect "notify: says which apps closed and that unsaved work is lost" yes yes \
  || { expect "notify: says which apps closed and that unsaved work is lost" yes no; cat "$CALLS"; }
grep -q "macOS ran short of memory" "$CALLS" && expect "notify: says why (memory)" yes yes || expect "notify: says why (memory)" yes no
expect "notify: the note is gone after"          no "$( [[ -e $T/run/desktop/restarted ]] && echo yes || echo no)"
: > "$CALLS"
"$G" notify
expect "notify: nothing without a note"          "" "$(cat "$CALLS")"
# No Hyprland answer (hung): still restarts, the note says apps closed.
: > "$CALLS"; echo 'not json' > "$CLIENTS"
"$G" desktop graphics > /dev/null
expect "desktop without an app list: still restarts" "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
"$G" notify
grep -q "Apps that were open were closed; anything not saved in them is lost." "$CALLS" \
  && expect "notify without an app list: says apps closed" yes yes || expect "notify without an app list: says apps closed" yes no
grep -q "graphics on the Mac failed" "$CALLS" && expect "notify: says why (graphics)" yes yes || expect "notify: says why (graphics)" yes no
# A garbage reason counts as graphics; the notification daemon not up: tried, then logged.
: > "$CALLS"
"$G" desktop 'x;rm -rf /' > /dev/null
expect "an unknown reason counts as graphics"    graphics "$(sed -n 's/^why=//p' "$T/run/desktop/restarted")"
touch "$NOTIFY_FAILS"
"$G" notify > /dev/null
grep -q "could not show the note" "$CALLS" && expect "notify without a daemon: logged" yes yes || expect "notify without a daemon: logged" yes no
rm -f "$NOTIFY_FAILS"
# The shell.
: > "$CALLS"
"$G" shell > /dev/null
expect "shell: only the shell restarts"          omarchy-restart-shell "$(grep -v '^logger' "$CALLS")"
# No desktop user known.
printf 'OMACVM_VM_TYPE=app\n' > "$T/env"
: > "$CALLS"
"$G" shell > /dev/null; rc=$?
expect "shell without a user: refused"           1 "$rc"
"$G" desktop graphics > /dev/null
expect "desktop without a user: still restarts"  "systemctl restart sddm" "$(grep '^systemctl' "$CALLS")"
"$G" bogus 2>/dev/null; rc=$?
expect "unknown mode: usage"                     2 "$rc"
exit $fail
