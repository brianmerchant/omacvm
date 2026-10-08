#!/bin/bash
# install.sh's checkout (~/.omacvm) follows OmacVM's releases (#291: main was
# at 3.0.6 while OmacVM.app updated to the 3.0.7 release, and `omacvm update`
# said "already up to date (3.0.6)"). Without a VM or the network: a local
# origin whose main is behind the release tags, a stand-in curl for GitHub's
# latest release, a throwaway HOME and a made-up OmacVM.app (test identity).
#   src/tests/follow-release.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() {   # WHAT TEXT NEEDLE
  if [[ $2 == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: no '$3' in: $2"; fail=1; fi
}
[[ -x $R/src/lib/follow-release.sh ]] || { echo "FAIL src/lib/follow-release.sh is missing"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home B=$T/bin W=$T/work O=$T/origin.git
mkdir -p "$H/Applications" "$B" "$W/src/lib"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# GitHub's latest release: the redirect curl reports (no file: offline).
cat > "$B/curl" <<EOF
#!/bin/bash
[[ -f $T/latest ]] || exit 6
echo "https://github.com/gillesgoetsch/omacvm/releases/tag/v\$(cat $T/latest)"
EOF
chmod +x "$B/curl"

# The origin: main stays at 3.0.6; the releases are tags off main.
cp "$R/omacvm" "$W/"; cp "$R"/src/lib/{app.sh,version.sh,identity.sh,follow-release.sh} "$W/src/lib/"
g() { git -C "$W" "$@" >/dev/null 2>&1; }
commit() { echo "$1" > "$W/src/VERSION"; git -C "$W" add -A; g commit -m "$1"; }
git -C "$W" init -q -b main; commit 3.0.6
g checkout -b rel; commit 3.0.7; g tag v3.0.7
commit 3.0.8; g tag v3.0.8
rm "$W/src/lib/follow-release.sh"; commit 3.0.9; g tag v3.0.9      # a tag that could not follow
g checkout v3.0.8; commit 3.0.10; g tag v3.0.10
g checkout main; echo x > "$W/x"; commit 3.0.6                     # main moves on, still 3.0.6
git clone -q --bare "$W" "$O"

CO=$H/.omacvm
fresh() { rm -rf "$CO"; git clone -q "$O" "$CO"; }
follow() {   # -> OUT, RC
  OUT=$(HOME=$H PATH="$B:$PATH" OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=org.omacvm.followrelease.none \
        "$CO/src/lib/follow-release.sh" "$CO" 2>&1); RC=$?
}
at() { git -C "$CO" describe --tags --exact-match HEAD 2>/dev/null || git -C "$CO" symbolic-ref -q --short HEAD; }
fake_app() {   # VERSION
  local a="$H/Applications/OmacVM Test.app"
  mkdir -p "$a/Contents/Resources/scripts" "$a/Contents/Resources/omacvm"
  : > "$a/Contents/Resources/scripts/create-vm.sh"
  plutil -create xml1 "$a/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string org.omacvm.app.test "$a/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$1" "$a/Contents/Info.plist"
}

# ---- #291: an install from before 3.0.9 (main, no setting) ----
fresh; echo 3.0.7 > "$T/latest"
expect "main is behind the release (the bug: git pull is up to date)" "3.0.6" "$(git -C "$CO" pull -q --ff-only && cat "$CO/src/VERSION")"
follow
expect "it moves to the latest release" "0 v3.0.7 3.0.7" "$RC $(at) $(cat "$CO/src/VERSION")"
has "and says so" "$OUT" "3.0.7: "
follow
expect "again: up to date" "1 v3.0.7" "$RC $(at)"
has "and says so" "$OUT" "already up to date (3.0.7)"
echo 3.0.8 > "$T/latest"; follow
expect "the next release, from a tag" "0 v3.0.8" "$RC $(at)"
echo 3.0.7 > "$T/latest"; follow
expect "a rolled back release: never back" "1 v3.0.8" "$RC $(at)"
echo 3.0.9 > "$T/latest"; follow
expect "a release without follow-release.sh: not taken (it could not follow the next one)" "1 v3.0.8" "$RC $(at)"

# ---- OmacVM.app newer than GitHub's latest: the app's version ----
echo 3.0.8 > "$T/latest"; fake_app 3.0.10; follow
expect "OmacVM.app 3.0.10: its tag" "0 v3.0.10" "$RC $(at)"
rm -rf "$H/Applications/OmacVM Test.app"

# ---- GitHub does not answer: the newest tag that can follow ----
fresh; rm -f "$T/latest"; follow
expect "offline: the newest tag that can follow" "0 v3.0.10" "$RC $(at)"

# ---- never moved ----
fresh; echo 3.0.7 > "$T/latest"; echo y > "$CO/x"; follow
expect "local changes: not moved" "1 main" "$RC $(at)"
has "and says so" "$OUT" "local changes"
fresh; git -C "$CO" config omacvm.follow ref; follow
expect "OMACVM_REF (a branch or tag on purpose): not moved" "1 main" "$RC $(at)"
rm -rf "${T:?}/dev"; git clone -q "$O" "$T/dev"
OUT=$(HOME=$H PATH="$B:$PATH" "$T/dev/src/lib/follow-release.sh" "$T/dev" 2>&1); RC=$?
expect "another clone (development): not moved" "1 main" "$RC $(git -C "$T/dev" symbolic-ref -q --short HEAD)"
git -C "$T/dev" config omacvm.follow release
HOME=$H "$T/dev/src/lib/follow-release.sh" --check "$T/dev"; expect "omacvm.follow=release: it follows" 0 $?
fresh; git -C "$CO" remote set-url origin "$T/nowhere.git"; follow
expect "git fetch fails: status 2, not moved" "2 main" "$RC $(at)"

# ---- the entry script: OmacVM.app newer ----
fresh; fake_app 3.0.10
entry() { HOME=$H PATH="$B:$PATH" OMACVM_TEST_IDENTITY=1 OMACVM_APP_ID=org.omacvm.followrelease.none "$1/omacvm" --version 2>&1; }
OUT=$(entry "$CO")
has "follows releases: omacvm update brings it up" "$OUT" "OmacVM.app 3.0.10 on this Mac. Use the app's: $H/Applications/OmacVM Test.app/Contents/Resources/omacvm/omacvm, or bring this one up to date: omacvm update"
git -C "$T/dev" config --unset omacvm.follow; OUT=$(entry "$T/dev")
has "another clone: the app's omacvm" "$OUT" "Use the app's: $H/Applications/OmacVM Test.app/Contents/Resources/omacvm/omacvm"
[[ $OUT != *"omacvm update"* ]] && echo "ok   another clone: not told to run omacvm update (it would not move)" ||
  { echo "FAIL another clone is told omacvm update: $OUT"; fail=1; }

exit $fail
