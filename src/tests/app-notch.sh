#!/bin/bash
# OmacVM.app's "Use the notch for the menu bar": on by default, an explicit
# choice kept, off without a notch; `omacvm check` reads the setting the same
# way. Compiles NotchSetting.swift on its own; a throwaway settings domain,
# no window, no VM.
#   src/tests/app-notch.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
D=org.omacvm.test.app-notch.$$
trap 'defaults delete "$D" >/dev/null 2>&1; rm -rf "$T" "$HOME/Library/Preferences/$D.plist"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The app's rules: `notch DOMAIN yes|no` prints the stored choice and what the VM gets.
cat > "$T/main.swift" <<'EOF'
import Foundation
let a = CommandLine.arguments
let d = UserDefaults(suiteName: a[1])!
let choice = NotchSetting.choice(stored: d.object(forKey: NotchSetting.key))
print(choice ? "on" : "off", NotchSetting.active(choice: choice, hasNotch: a[2] == "yes") ? "on" : "off")
EOF
swiftc -module-cache-path "$T/mc" -o "$T/notch" "$R/app/app/Sources/OmacVM/NotchSetting.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL NotchSetting.swift does not compile on its own"; exit 1; }

# omacvm check's line, pointed at the throwaway domain.
line=$(grep -m1 'defaults read org.omacvm.app useNotch' "$R/src/cmd/check.sh") ||
  { echo "FAIL src/cmd/check.sh no longer reads useNotch"; exit 1; }
line=${line//org.omacvm.app/$D}
check_reads() { local n; eval "$line"; [[ $n == 1 ]] && echo on || echo off; }

case_() {   # WHAT STORED(unset|true|false) NOTCH(yes|no) WANT_CHOICE WANT_ACTIVE
  if [[ $2 == unset ]]; then defaults delete "$D" >/dev/null 2>&1; else defaults write "$D" useNotch -bool "$2"; fi
  expect "$1" "$4 $5" "$("$T/notch" "$D" "$3")"
  expect "$1 (omacvm check)" "$4" "$(check_reads)"
}

case_ "never touched, notch: on"              unset yes on  on
case_ "never touched, no notch: off"          unset no  on  off
case_ "switched off, notch: stays off"        false yes off off
case_ "switched off, no notch: off"           false no  off off
case_ "switched on, notch: on"                true  yes on  on
case_ "switched on, no notch: off"            true  no  on  off

# A setting written by `defaults write` as a number (1/0) counts the same.
defaults write "$D" useNotch -int 0
expect "stored 0: off" "off off" "$("$T/notch" "$D" yes)"

exit $fail
