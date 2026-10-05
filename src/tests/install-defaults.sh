#!/bin/bash
# The install dialog's defaults (app/app/Sources/OmacVM/InstallMemory.swift):
# which copy it preselects, and that "Run Without Installing" and updates do
# what they say. Fake folders and a defaults suite of its own: the app's
# settings (org.omacvm.app) are never read or written.
#   src/tests/install-defaults.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
# The defaults suite is a file in the temporary folder (an absolute path), so
# nothing lands in ~/Library/Preferences.
suite=$tmp/defaults/org.omacvm.test.install-defaults
trap 'rm -rf "$tmp"' EXIT
swiftc -O -o "$tmp/install-tests" \
  "$R/app/app/Sources/OmacVM/InstallMemory.swift" "$R/src/tests/install-defaults/main.swift"
mkdir -p "$tmp/defaults"
"$tmp/install-tests" "$tmp/root" "$suite"
