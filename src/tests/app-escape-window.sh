#!/bin/bash
# OmacVM.app's "Escape combo" setting and where a VM's window opens:
# - the setting lives in OmacVM Gestures' own settings domain (Gestures reads
#   it there, other routes set it with defaults write): "pointer" by default,
#   "all" when chosen, anything else counts as "pointer", as Gestures reads it;
# - the window opens on the display under the pointer, else the one with the
#   active menu bar; with one display QEMU keeps its own frame.
# Compiles EscapeSetting.swift and WindowPlacement.swift on their own; a
# throwaway settings domain, no window, no VM.
#   src/tests/app-escape-window.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
D=org.omacvm.test.escape.$$
trap 'defaults delete "$D" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$D.plist"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
cat > "$T/main.swift" <<'SWIFT'
import Foundation
import CoreGraphics
let a = CommandLine.arguments
switch a[1] {
case "escape":   // DOMAIN [set pointer|all]
  let d = UserDefaults(suiteName: a[2])!
  if a.count > 4 { EscapeSetting.set(EscapeSetting.Choice(rawValue: a[4])!, d) }
  print(EscapeSetting.current(d).rawValue)
case "place":    // pointerX pointerY menuBar|- [id x y w h]...
  var screens: [WindowPlacement.Screen] = []
  var i = 5
  while i + 4 < a.count + 0 {
    screens.append(.init(id: UInt32(a[i])!, frame: CGRect(x: Double(a[i + 1])!, y: Double(a[i + 2])!, width: Double(a[i + 3])!, height: Double(a[i + 4])!)))
    i += 5
  }
  let p = CGPoint(x: Double(a[2])!, y: Double(a[3])!)
  print(WindowPlacement.display(pointer: p, screens: screens, menuBar: UInt32(a[4])).map { String($0) } ?? "qemu")
default: exit(2)
}
SWIFT
swiftc -module-cache-path "$T/mc" -o "$T/t" "$R/app/app/Sources/OmacVM/EscapeSetting.swift" \
  "$R/app/app/Sources/OmacVM/WindowPlacement.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL EscapeSetting.swift / WindowPlacement.swift do not compile on their own"; exit 1; }

# The setting.
expect "escape combo: never chosen: the monitor under the pointer" pointer "$("$T/t" escape "$D")"
expect "escape combo: all monitors chosen" all "$("$T/t" escape "$D" set all)"
expect "... read back" all "$("$T/t" escape "$D")"
expect "... and back to the pointer's" pointer "$("$T/t" escape "$D" set pointer)"
defaults write "$D" EscapeSwipe ALL
expect "written by hand as ALL: all (Gestures compares without case)" all "$("$T/t" escape "$D")"
defaults write "$D" EscapeSwipe -int 1
expect "something else: the pointer's" pointer "$("$T/t" escape "$D")"
# Gestures reads the same key in the same domain.
grep -q 'CFSTR("EscapeSwipe"), GESTURES_DOMAIN' "$R/src/gestures/mac/omacvm-gestures.c" &&
  grep -q 'define GESTURES_DOMAIN CFSTR("org.omacvm.gestures")' "$R/src/gestures/mac/omacvm-gestures.c" &&
  grep -q 'static let domain = "org.omacvm.gestures"' "$R/app/app/Sources/OmacVM/EscapeSetting.swift" &&
  grep -q 'static let key = "EscapeSwipe"' "$R/app/app/Sources/OmacVM/EscapeSetting.swift" &&
  echo "ok   the app and Gestures use the same domain and key" || { echo "FAIL the app and Gestures use another domain or key"; fail=1; }

# Where the window opens (AppKit coordinates: y up from the main display's bottom).
mini="1 0 0 2560 1440"                                   # a Mac mini with one LG UltraFine 5K
mbp="1 0 0 1728 1117 2 -96 1117 1920 1200"               # MacBook Pro, an external display above it
expect "one display (Mac mini): QEMU's own frame" qemu "$("$T/t" place 100 100 1 $mini)"
expect "MacBook, pointer on the external: there" 2 "$("$T/t" place 500 1500 1 $mbp)"
expect "MacBook, pointer on the built-in: there" 1 "$("$T/t" place 500 500 2 $mbp)"
expect "pointer on no display (between them): the active menu bar's" 2 "$("$T/t" place 5000 5000 2 $mbp)"
expect "neither known: QEMU's own frame" qemu "$("$T/t" place 5000 5000 7 $mbp)"
exit $fail
