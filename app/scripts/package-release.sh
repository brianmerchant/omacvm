#!/bin/bash
# Zip dist/OmacVM.app for a GitHub release: dist/OmacVM-<version>.zip and its
# .sha256, the version from src/VERSION, then the app's update feed
# (scripts/appcast.sh: OmacVM-appcast.json and .sig) once a release key
# exists. Upload them all to the release v<version>; omacvm build --vm-type
# app and omacvm update download the zip from there, installed apps the feed.
#   scripts/package-release.sh   (after scripts/build-app.sh --release)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION=$(cat "$REPO/src/VERSION")
APP=$ROOT/dist/OmacVM.app
ZIP=$ROOT/dist/OmacVM-$VERSION.zip
[[ -d $APP ]] || die "no $APP: run scripts/build-app.sh --release first"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] ||
  die "the app is $(plist CFBundleShortVersionString), src/VERSION says $VERSION: build it again"
[[ $(plist OmacVMCommit) == "$(git -C "$REPO" rev-parse HEAD)" ]] ||
  die "the app was built from another commit: build it again (scripts/build-app.sh --release)"
[[ -z $(git -C "$REPO" status --porcelain) ]] || die "uncommitted changes: a release comes from a clean tree"
# The runtime's build log holds local home paths. It once got into the
# history (037fcf58, filtered out since); a branch made before that brings it
# back until it is rebased onto the filtered history.
[[ -z $(git -C "$REPO" rev-list --objects HEAD | grep '\.build-runtime\.log$') ]] ||
  die "runtime/.build-runtime.log is in this history: rebase the branches made from the old app-in first"
# Releases are signed with OmacVM's Developer ID (the team goes into the
# signed update feed, which omacvm build --vm-type app, omacvm update and the
# app's own updates check): no ad hoc build.
codesign --verify --deep --strict "$APP" || die "the app's signature does not verify"
TEAM=$("$REPO/src/release/release-key.sh" team "$APP") ||
  die "the app is not signed with a Developer ID: build it with OMACVM_SIGN_ID"
echo "==> signed with the Developer ID of team $TEAM"

rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
printf '==> %s (%s)\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)"
printf '==> %s\n' "$ZIP.sha256"

# The update feed. Publish the release as a pre-release first and try its
# zip; installed apps see it only once the release is marked latest.
if [[ -f $REPO/src/lib/release-key.pub ]]; then
  "$ROOT/scripts/appcast.sh"
else
  echo "==> no src/lib/release-key.pub yet: no update feed (apps do not check for updates until a release has one)"
fi
