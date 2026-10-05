#!/bin/bash
# The Bridge's brightness keys read from the keyboard (hid-keys.swift): the
# real reader with made-up keyboards (MacBook, Magic Keyboard USB + Bluetooth,
# a PC keyboard),
# then this Mac's own keyboards' F-key maps, read only (no key pressed,
# no device opened, no permission needed).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/hid-test" "$HERE/keys-model.swift" "$HERE/hid-keys.swift" "$HERE/tests/hid/main.swift" -framework IOKit
"$T/hid-test"
