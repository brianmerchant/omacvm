#!/bin/bash
# The update feed for a release (docs/adr/0033): dist/OmacVM-appcast.json
# and its Ed25519 signature dist/OmacVM-appcast.json.sig, for the zip that
# package-release.sh made. Upload both to the GitHub release v<version> with
# the zip; installed apps find them through releases/latest.
#   scripts/appcast.sh      (package-release.sh runs it)
# Signed by src/release/release-key.sh: the main key from the Keychain
# (generic password, service org.omacvm.release-key), or the spare in
# OMACVM_RELEASE_KEY_FILE; checked against src/lib/release-key.pub and
# release-key-spare.pub, which every app carries (docs/release-keys.md).
# "devid_teams" is the Developer ID team the zip's app is signed with (plus
# OMACVM_EXTRA_TEAMS while a change of team goes out); OMACVM_NEXT_SPARE_KEY
# names a new spare key.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

VERSION=$(cat "$REPO/src/VERSION")
ZIP=$ROOT/dist/OmacVM-$VERSION.zip
FEED=$ROOT/dist/OmacVM-appcast.json
PUB=$REPO/src/lib/release-key.pub
KEYS=$REPO/src/release/release-key.sh
[[ -f $PUB ]] || die "no src/lib/release-key.pub yet: no update feed (installed apps check nothing until a release has a key)"
[[ -f $ZIP ]] || die "no $ZIP: run scripts/package-release.sh first"
[[ $VERSION =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || die "src/VERSION ($VERSION) is not a release version"

# The zip's app is the one the feed promises: version, bundle id, Developer ID.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ditto -x -k "$ZIP" "$tmp"
APP=$tmp/OmacVM.app
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[[ $(plist CFBundleShortVersionString) == "$VERSION" ]] || die "the zip's app is not $VERSION"
[[ $(plist CFBundleIdentifier) == org.omacvm.app ]] || die "the zip's app is not org.omacvm.app"
# The team it is signed with (a Developer ID, or this fails) goes into the feed.
TEAMS=$("$KEYS" teams "$APP") || die "the zip's app is not signed with a Developer ID"
SPARE=$("$KEYS" spare) || die "OMACVM_NEXT_SPARE_KEY is not a public key"
MIN=$(plist LSMinimumSystemVersion)

URL=https://github.com/gillesgoetsch/omacvm/releases/download/v$VERSION/OmacVM-$VERSION.zip
LENGTH=$(stat -f %z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{ print $1 }')
cat > "$FEED" <<EOF
{
  "schema": 1,
  "kind": "app-feed",
  "version": "$VERSION",
  "url": "$URL",
  "length": $LENGTH,
  "sha256": "$SHA",
  "minimum_macos": "$MIN",
  "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v$VERSION",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "devid_teams": $TEAMS$SPARE
}
EOF

# Signed, then checked with the keys the apps know, or nothing goes out.
"$KEYS" sign "$FEED" || { rm -f "$FEED"; die "the feed was not signed"; }
python3 "$REPO/src/release/keys.py" app-feed "$FEED" "$VERSION" > /dev/null || { rm -f "$FEED" "$FEED.sig"; die "the feed does not read back"; }
printf '==> %s\n==> %s\n' "$FEED" "$FEED.sig"
