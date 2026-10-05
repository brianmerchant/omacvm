#!/bin/bash
# OmacVM's release keys on the Mac's command line (src/release/keys.py,
# release-key.sh, the CLI's OmacVM.app download in src/lib/app.sh), with
# throwaway keys: either shipped key signs, other keys and changed documents
# are refused, the Developer ID teams come from the signed document (missing,
# empty or another team: refused), a named spare is trusted from then on,
# test keys count nowhere inside a release app. No network beyond 127.0.0.1.
#   src/tests/release-keys.sh
# OMACVM_TEST_DEVID_APP: a Developer ID signed org.omacvm.app (a release
# build) for the download that passes; skipped without it.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
SERVER=""
trap '[[ -n $SERVER ]] && { kill "$SERVER"; wait "$SERVER"; } 2>/dev/null; rm -rf "$T"' EXIT
source "$R/src/tests/release-test-keys.sh"
KEYS=$R/src/release/keys.py

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
verdict() { python3 "$KEYS" verify "$1" "$2" >/dev/null 2>&1 && echo good || echo refused; }   # KIND FILE

# doc FILE KIND [EXTRA-JSON-FIELDS] [KEY]: a small signed document.
doc() {
  printf '{"schema": 1, "kind": "%s", "version": "9.9.9", "devid_teams": ["722686Y34B"]%s}\n' "$2" "${3:-}" > "$1"
  sign_doc "$1" "${4:-}"
}

# ---- either key, nothing else ----
D=$T/doc.json
doc "$D" control-manifest
expect "signed with the main key" good "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" spare-key
expect "signed with the spare key" good "$(verdict control-manifest "$D")"
doc "$D" control-manifest "" stranger-key
expect "signed with another key: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest
printf ' ' >> "$D"
expect "a byte added after signing: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest; rm -f "$D.sig"
expect "no signature: refused" refused "$(verdict control-manifest "$D")"
doc "$D" control-manifest; echo "bm90IGEgc2ln" > "$D.sig"
expect "garbage signature: refused" refused "$(verdict control-manifest "$D")"
doc "$D" app-feed
expect "another kind: refused" refused "$(verdict control-manifest "$D")"
expect "the shipped keys only (no test keys): refused" refused "$(OMACVM_RELEASE_TEST_KEYS="" verdict app-feed "$D")"
python3 "$KEYS" release-check "$D" >/dev/null 2>&1
expect "release-check: a test key is not a shipped key" 1 $?

# ---- the teams ----
while IFS='|' read -r what teams; do
  printf '{"schema": 1, "kind": "app-feed"%s}\n' "$teams" > "$D"; sign_doc "$D"
  expect "$what: refused" refused "$(verdict app-feed "$D")"
done <<'EOF'
no devid_teams|
empty devid_teams|, "devid_teams": []
devid_teams as a string|, "devid_teams": "722686Y34B"
a lower-case team|, "devid_teams": ["722686y34b"]
a team with a quote|, "devid_teams": ["722686Y3\"B"]
a team twice|, "devid_teams": ["722686Y34B", "722686Y34B"]
five teams|, "devid_teams": ["AAAAAAAAA1", "AAAAAAAAA2", "AAAAAAAAA3", "AAAAAAAAA4", "AAAAAAAAA5"]
EOF
printf '{"schema": 1, "kind": "app-feed", "devid_teams": ["722686Y34B", "ABCDE12345"]}\n' > "$D"; sign_doc "$D"
expect "two teams (a change of Developer ID)" good "$(verdict app-feed "$D")"

# ---- a named spare: kept as the signed document, trusted from then on ----
"$T/sign" keygen "$T/next-key" > "$T/next-key.pub"
"$T/sign" keygen "$T/third-key" > "$T/third-key.pub"
STORE=$OMACVM_SETTINGS_DIR/release-keys
doc "$D" control-manifest "" next-key
expect "the new spare before it was named: refused" refused "$(verdict control-manifest "$D")"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" stranger-key
verdict app-feed "$T/naming.json" >/dev/null
expect "named by a stranger: nothing kept" 0 "$(ls "$STORE" 2>/dev/null | wc -l | tr -d ' ')"
doc "$T/naming.json" app-feed ", \"next_spare_key\": \"$(cat "$T/next-key.pub")\"" spare-key
expect "a feed naming a new spare (signed by the spare)" good "$(verdict app-feed "$T/naming.json")"
expect "kept: the document and its signature" 2 "$(ls "$STORE" 2>/dev/null | wc -l | tr -d ' ')"
expect "signed with the named spare: accepted from then on" good "$(verdict control-manifest "$D")"
doc "$T/naming2.json" control-manifest ", \"next_spare_key\": \"$(cat "$T/third-key.pub")\"" next-key
verdict control-manifest "$T/naming2.json" >/dev/null
doc "$D" control-manifest "" third-key
expect "the named spare names the next one: a chain" good "$(verdict control-manifest "$D")"
doc "$T/bad.json" app-feed ', "next_spare_key": "bm90IGEga2V5"'
expect "next_spare_key not a key: refused" refused "$(verdict app-feed "$T/bad.json")"
# The Swift side keeps the same files: OmacVM.app and the Bridge trust the same keys.
for f in "$STORE"/*.json; do
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read()); d[len(d) // 2] ^= 1
open(p, "wb").write(bytes(d))
PY
done
expect "kept documents changed on disk: the named keys are not trusted" refused "$(verdict control-manifest "$D")"
rm -rf "$STORE"; mkdir -p "$STORE"
cp "$T/next-key.pub" "$STORE/0123456789abcdef.json"; echo x > "$STORE/0123456789abcdef.json.sig"
doc "$D" control-manifest "" next-key
expect "a bare key file in the folder: not trusted" refused "$(verdict control-manifest "$D")"
rm -rf "$STORE"

# ---- test keys count nowhere inside a release app ----
fake() {   # BUNDLE-ID: a copy of keys.py and the shipped keys in an app bundle
  local a=$T/Fake-$1.app
  mkdir -p "$a/Contents/Resources/omacvm/src/release" "$a/Contents/Resources/omacvm/src/lib"
  cp "$KEYS" "$a/Contents/Resources/omacvm/src/release/"
  cp "$R"/src/lib/release-key*.pub "$a/Contents/Resources/omacvm/src/lib/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $1" "$a/Contents/Info.plist" >/dev/null
  echo "$a/Contents/Resources/omacvm/src/release/keys.py"
}
doc "$D" app-feed
expect "test keys in a test build (org.omacvm.sutest): used" 0 "$(python3 "$(fake org.omacvm.sutest)" verify app-feed "$D" >/dev/null 2>&1; echo $?)"
expect "test keys in a release build (org.omacvm.app): ignored" 1 "$(python3 "$(fake org.omacvm.app)" verify app-feed "$D" >/dev/null 2>&1; echo $?)"

# ---- the CLI's download of OmacVM.app (src/lib/app.sh) ----
source "$R/src/lib/app.sh"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$T/www"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" > "$T/server.log" 2>&1 &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.3; done
APP_DOWNLOADS=http://127.0.0.1:$PORT
# release VERSION APP [TEAMS] [KEY]: the zip of APP and its signed feed, as appcast.sh makes them.
release() {
  local d=$T/www/v$1 z
  rm -rf "$d"; mkdir -p "$d"; z=$d/OmacVM-$1.zip
  ditto -c -k --keepParent "$2" "$z"
  printf '{"schema": 1, "kind": "app-feed", "version": "%s", "url": "%s", "length": %s, "sha256": "%s", "devid_teams": [%s]}\n' \
    "$1" "$APP_DOWNLOADS/v$1/OmacVM-$1.zip" "$(stat -f %z "$z")" "$(shasum -a 256 "$z" | cut -d' ' -f1)" "${3:-\"ABCDE12345\"}" \
    > "$d/OmacVM-appcast.json"
  sign_doc "$d/OmacVM-appcast.json" "${4:-}"
}
download() {   # VERSION: ok, or app_download's reason
  rm -rf "$T/dl"; mkdir -p "$T/dl"
  if app_download "$1" "$T/dl" > /dev/null 2> "$T/err"; then echo ok; else tr '\r' '\n' < "$T/err" | grep -E 'not installed|failed' | tail -1; fi
}
# An ad hoc signed org.omacvm.app (built from source), version 9.9.9.
A=$T/adhoc/OmacVM.app
mkdir -p "$A/Contents/MacOS"
cp /usr/bin/true "$A/Contents/MacOS/OmacVM"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string org.omacvm.app" -c "Add :CFBundleShortVersionString string 9.9.9" \
  -c "Add :CFBundleExecutable string OmacVM" "$A/Contents/Info.plist" >/dev/null
codesign --force --sign - "$A" 2>/dev/null
expect "no feed for the release: refused" yes "$([[ $(download 9.9.8) == "no signed update feed"* ]] && echo yes || echo "$(download 9.9.8)")"
release 9.9.9 "$A" "" stranger-key
expect "feed signed by another key: refused" yes "$([[ $(download 9.9.9) == *"does not check out"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
cp "$T/www/v9.9.9/OmacVM-appcast.json" "$T/feed-9.9.9"
release 9.9.8 "$A"; cp "$T/feed-9.9.9" "$T/www/v9.9.8/OmacVM-appcast.json"
cp "$T/www/v9.9.9/OmacVM-appcast.json.sig" "$T/www/v9.9.8/"
expect "the feed of another version (replayed): refused" yes "$([[ $(download 9.9.8) == *"does not check out"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
printf 'x' >> "$T/www/v9.9.9/OmacVM-9.9.9.zip"
expect "zip changed after the feed was signed: refused" yes "$([[ $(download 9.9.9) == *"checksum"* ]] && echo yes || echo no)"
release 9.9.9 "$A" '"722686Y34B"'
expect "an ad hoc app: refused (no team the feed names)" yes "$([[ $(download 9.9.9) == *"Developer ID the signed feed names (722686Y34B)"* ]] && echo yes || echo no)"
if [[ -n ${OMACVM_TEST_DEVID_APP:-} ]]; then
  V=$(defaults read "$OMACVM_TEST_DEVID_APP/Contents/Info" CFBundleShortVersionString)
  TEAM=$(codesign -dv "$OMACVM_TEST_DEVID_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"$TEAM\""
  expect "a Developer ID app of the team the feed names: downloaded and checked" ok "$(download "$V")"
  expect "... it is there" yes "$([[ -d $T/dl/x/OmacVM.app ]] && echo yes || echo no)"
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"0000000000\", \"ABCDE12345\""
  expect "the same app, the feed names other teams: refused" yes "$([[ $(download "$V") == *"Developer ID the signed feed names"* ]] && echo yes || echo no)"
  release "$V" "$OMACVM_TEST_DEVID_APP" "\"0000000000\", \"$TEAM\"" spare-key
  expect "old and new team listed, signed with the spare: downloaded" ok "$(download "$V")"
else
  echo "skip the Developer ID app download (set OMACVM_TEST_DEVID_APP to a release build)"
fi

exit $fail
