#!/bin/bash
# Builds the Touch ID panel's test tool (tests/panel/main.swift) into <out dir>
# with what it needs beside it: the fonts, the stock themes, the OmacVM icon.
#   tests/panel/build.sh <out dir>
# Then: <out dir>/panel-tests mock [<png dir>]   (safe anywhere: never on screen)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=${1:?usage: build.sh <out dir>}
mkdir -p "$out"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -o "$out/panel-tests" \
  control_policy.swift touchid_policy.swift touchid_theme.swift touchid_panel_model.swift touchid_panel.swift tests/panel/main.swift \
  -framework AppKit -framework LocalAuthentication -framework LocalAuthenticationEmbeddedUI
cp fonts/JetBrainsMono-Regular.ttf fonts/JetBrainsMono-Bold.ttf tests/fixtures/omarchy-themes.tsv "$out/"
[[ -f $out/omacvm.png ]] || ../../icon/make-icns.sh "$out/omacvm.png" 256
