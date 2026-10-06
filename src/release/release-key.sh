#!/bin/bash
# Signing a release's documents (docs/release-keys.md): OmacVM.app's update
# feed (app/scripts/appcast.sh), the control centre's manifest (manifest.py
# build --out) and the prebuilt images' manifests (src/prebuilt/make-image.sh).
#   release-key.sh sign FILE     FILE.sig with the main key from this Mac's
#                                Keychain (generic password, service
#                                org.omacvm.release-key), or the key in
#                                OMACVM_RELEASE_KEY_FILE (the spare, when the main
#                                key is lost); then checked against the public
#                                keys the apps ship: a signature they would
#                                refuse never stays. The Keychain key signs
#                                only inside a release run: release.sh sets
#                                OMACVM_RELEASE_RUN=VERSION, and this copy of
#                                the repo must be at that version (src/VERSION),
#                                with no changed tracked files, and at the tag
#                                vVERSION if it exists. Test documents are
#                                signed with a test key (src/tests), never this.
#   release-key.sh team [APP]    the Developer ID team the release is signed with:
#                                APP's (the release build), else that of the
#                                identity OMACVM_SIGN_ID names
#   release-key.sh teams [APP]   the "devid_teams" JSON list: that team, plus
#                                OMACVM_EXTRA_TEAMS (space-separated; the old team
#                                while a change of Developer ID goes out)
#   release-key.sh spare         the "next_spare_key" field from
#                                OMACVM_NEXT_SPARE_KEY (a new spare's public key),
#                                with a comma in front, or nothing
#   release-key.sh revoked       the "revoked_keys" field from OMACVM_REVOKED_KEYS
#                                (named spares that leaked, space-separated; the
#                                document must be signed by a shipped key), with
#                                a comma in front, or nothing
# The private key only goes through a pipe into sign.swift; it is never
# written to a file or printed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { printf 'release-key.sh: %s\n' "$*" >&2; exit 1; }
devid() {   # TEAM: Developer ID Application of TEAM, issued by Apple
  printf 'anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "%s"' "$1"
}

team() {
  local t
  if [[ -n ${1:-} ]]; then
    t=$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [[ $t =~ ^[A-Z0-9]{10}$ ]] || die "$1 has no Developer ID team"
    codesign --verify --deep --strict -R="$(devid "$t")" "$1" 2>/dev/null || die "$1 is not signed with a Developer ID of team $t"
  else
    [[ -n ${OMACVM_SIGN_ID:-} ]] || die "no app given and no OMACVM_SIGN_ID: which Developer ID signs this release?"
    t=$(security find-identity -v -p codesigning | grep -F -- "$OMACVM_SIGN_ID" |
      sed -n 's/.*"Developer ID Application: .* (\([A-Z0-9]\{10\}\))"$/\1/p' | head -1)
    [[ $t =~ ^[A-Z0-9]{10}$ ]] || die "OMACVM_SIGN_ID ($OMACVM_SIGN_ID) is not a Developer ID Application identity on this Mac"
  fi
  echo "$t"
}

# The real key only for a real release run (see sign above). A test build
# or a dev checkout that calls sign by mistake stops here, before the
# Keychain is read.
release_run() {
  local v=${OMACVM_RELEASE_RUN:-} repo cur tag
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "not a release run (OMACVM_RELEASE_RUN unset): the release key signs only from release.sh; sign test documents with a test key"
  repo=$(cd "$HERE/../.." && pwd)
  cur=$(cat "$repo/src/VERSION" 2>/dev/null || true)
  [[ $cur == "$v" ]] || die "release run $v, but $repo is at version ${cur:-?}: not signing"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "$repo is not a git checkout: not signing"
  [[ -z $(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null) ]] ||
    die "$repo has changed tracked files: the release key signs only a clean tree"
  if tag=$(git -C "$repo" rev-parse -q --verify "refs/tags/v$v^{commit}" 2>/dev/null); then
    [[ $tag == "$(git -C "$repo" rev-parse HEAD)" ]] || die "tag v$v is not this checkout's HEAD: not signing"
  fi
}

case ${1:-} in
  sign)
    f=${2:?usage: release-key.sh sign FILE}
    [[ -f $f ]] || die "no $f"
    rm -f "$f.sig"
    if [[ -n ${OMACVM_RELEASE_KEY_FILE:-} ]]; then
      swift "$HERE/sign.swift" sign "$OMACVM_RELEASE_KEY_FILE" "$f" > "$f.sig" || { rm -f "$f.sig"; die "signing with OMACVM_RELEASE_KEY_FILE failed"; }
    else
      release_run
      security find-generic-password -s org.omacvm.release-key -w 2>/dev/null | swift "$HERE/sign.swift" sign - "$f" > "$f.sig" ||
        { rm -f "$f.sig"; die "no release key: Keychain item org.omacvm.release-key, or OMACVM_RELEASE_KEY_FILE"; }
    fi
    python3 "$HERE/keys.py" release-check "$f" ||
      { rm -f "$f.sig"; die "the signature does not match src/lib/release-key.pub or release-key-spare.pub: wrong key, no signature kept"; }
    ;;
  team) team "${2:-}" ;;
  teams)
    t=$(team "${2:-}"); out="\"$t\""
    for x in ${OMACVM_EXTRA_TEAMS:-}; do
      [[ $x =~ ^[A-Z0-9]{10}$ ]] || die "OMACVM_EXTRA_TEAMS: $x is not a team ID"
      [[ $x == "$t" ]] || out+=", \"$x\""
    done
    echo "[$out]"
    ;;
  spare)
    k=${OMACVM_NEXT_SPARE_KEY:-}
    [[ -z $k ]] && exit 0
    [[ $k =~ ^[A-Za-z0-9+/]{43}=$ ]] && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import keys; sys.exit(0 if keys.key(sys.argv[2]) else 1)' "$HERE" "$k" ||
      die "OMACVM_NEXT_SPARE_KEY is not a public key (base64 of 32 bytes)"
    printf ', "next_spare_key": "%s"' "$k"
    ;;
  revoked)
    out=""
    for k in ${OMACVM_REVOKED_KEYS:-}; do
      [[ $k =~ ^[A-Za-z0-9+/]{43}=$ ]] && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import keys; sys.exit(0 if keys.key(sys.argv[2]) else 1)' "$HERE" "$k" ||
        die "OMACVM_REVOKED_KEYS: $k is not a public key (base64 of 32 bytes)"
      [[ $out == *"\"$k\""* ]] || out+="${out:+, }\"$k\""
    done
    [[ -z $out ]] || printf ', "revoked_keys": [%s]' "$out"
    ;;
  *) sed -n '2,30s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
