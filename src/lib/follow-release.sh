#!/bin/bash
# The checkout install.sh makes (~/.omacvm) follows OmacVM's releases, as
# OmacVM.app does: the newest release's tag (GitHub's latest release), or
# OmacVM.app's version when the app on this Mac is newer still (#291: main
# was behind the app's release and `omacvm update` said up to date). bash 3.2.
#   follow-release.sh --check DIR   status 0: DIR follows releases
#   follow-release.sh DIR           moves DIR there, only forward; status 0:
#                                   moved, 1: not moved (says why), 2: failed
# Follows releases: `git config omacvm.follow` is `release` (install.sh
# without OMACVM_REF), or unset in ~/.omacvm on its branch main (installs
# before 3.0.9). Any other value (OMACVM_REF: a branch or a tag) or another
# clone (a development checkout): never moved. Local changes: never moved.
# On a branch with an upstream it pulls first (--ff-only), as before; it goes
# to a release's tag only when that tag has this file (older ones could not
# follow the next release) and is newer than the checkout, or ahead of it.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/version.sh"
RELEASES=${OMACVM_RELEASES_URL:-https://github.com/gillesgoetsch/omacvm/releases}

follows() {   # DIR
  local f b
  f=$(git -C "$1" config --get omacvm.follow 2>/dev/null) || f=""
  [[ $f == release ]] && return 0
  [[ -z $f && -d $HOME/.omacvm && $1 -ef $HOME/.omacvm ]] || return 1
  b=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null) || return 1
  [[ $b == main ]]
}

latest() {   # the latest release's version (GitHub's redirect), else the newest vX.Y.Z tag
  local u
  u=$(curl -fsS --max-time 20 -o /dev/null -w '%{redirect_url}' "$RELEASES/latest" 2>/dev/null) || u=""
  case $u in
    */tag/v[0-9]*) u=${u##*/tag/v}; [[ $u =~ ^[0-9]+(\.[0-9]+)*$ ]] && { echo "$u"; return 0; } ;;
  esac
  git -C "$D" tag -l 'v[0-9]*' | sed 's/^v//' | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1
}

usable() {   # VERSION: its tag is here, can follow the next release and goes forward
  local t=refs/tags/v$1 c
  c=$(git -C "$D" rev-parse -q --verify "$t^{commit}") || return 1
  git -C "$D" cat-file -e "$t:src/lib/follow-release.sh" 2>/dev/null || return 1
  [[ $c != $(git -C "$D" rev-parse HEAD) ]] || return 1
  version_lt "$(cat "$D/src/VERSION")" "$1" || git -C "$D" merge-base --is-ancestor HEAD "$c"
}

if [[ ${1:-} == --check ]]; then follows "$2"; exit; fi
D=$1
follows "$D" || exit 1
if [[ -n $(git -C "$D" status --porcelain --untracked-files=no) ]]; then
  echo "this checkout has local changes: not moved to the newest release ($D)"; exit 1
fi
before=$(git -C "$D" rev-parse HEAD)
git -C "$D" fetch -q --tags origin || { echo "git fetch failed in $D" >&2; exit 2; }
if git -C "$D" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
  git -C "$D" merge -q --ff-only '@{u}' || { echo "git pull failed in $D" >&2; exit 2; }
fi
want=$(latest)
# OmacVM.app newer than the latest release (it went to a release since
# rolled back, or GitHub did not answer): the app's own version.
if [[ -f $here/app.sh ]] && a=$(source "$here/app.sh" && omacvm_app_newer "${want:-0}"); then
  usable "${a#*$'\t'}" && want=${a#*$'\t'}
fi
if [[ -n $want ]] && usable "$want"; then
  git -C "$D" checkout -q --detach "refs/tags/v$want" || { echo "git checkout v$want failed in $D" >&2; exit 2; }
  git -C "$D" config omacvm.follow release   # off main now: say it (installs before 3.0.9)
fi
now=$(cat "$D/src/VERSION")
if [[ $(git -C "$D" rev-parse HEAD) == "$before" ]]; then echo "already up to date ($now)"; exit 1; fi
echo "$now: $(git -C "$D" rev-list --count "$before..HEAD") new commits"
