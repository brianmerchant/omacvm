#!/bin/bash
# build-live.sh's work folder lock (src/vm/live/workdir-lock.sh): a second
# build waits for the first instead of sharing its download and files; a lock
# left by a build that is gone is taken over. No VM, no download.
#   src/tests/build-live-lock.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
W=$T/cache/build-live
# one build: info/die as build-live.sh has them; it holds the lock HOLD s, then lets go
build() {   # NAME HOLD [WAIT]
  bash -c '
    set -euo pipefail
    info() { echo "info: $*"; }
    die() { echo "die: $*"; exit 1; }
    source "$1"
    WORKDIR_LOCK_WAIT=${4:-3600} workdir_lock "$2"
    trap "workdir_unlock \"$2\"" EXIT
    echo "$(date +%s) in $5"; sleep "$3"; echo "$(date +%s) out $5"' _ "$R/src/vm/live/workdir-lock.sh" "$W" "$2" "${3:-3600}" "$1"
}

# 1. two at once: the second starts only after the first is done, and says why it waits
build A 3 > "$T/a.out" 2>&1 &
sleep 0.5
build B 0 > "$T/b.out" 2>&1
wait
a_out=$(awk '$2 == "out" {print $1}' "$T/a.out"); b_in=$(awk '$2 == "in" {print $1}' "$T/b.out")
expect "the second build waits for the first" yes "$([[ -n $a_out && -n $b_in ]] && (( b_in >= a_out )) && echo yes || echo "a out ${a_out:-?}, b in ${b_in:-?}")"
expect "it says why it waits" yes "$(grep -q 'info: another omacvm build is making its live installer' "$T/b.out" && echo yes || cat "$T/b.out")"
expect "the lock is gone after both" no "$([[ -e $W.lock ]] && echo yes || echo no)"

# 2. a lock left by a build that is gone (its pid does not run): taken over at once
mkdir -p "$W.lock"; sh -c 'echo $$' > "$W.lock/pid"
t0=$(date +%s); build C 0 > "$T/c.out" 2>&1; t1=$(date +%s)
expect "a stale lock is taken over" yes "$(grep -q ' in C' "$T/c.out" && (( t1 - t0 < 3 )) && echo yes || cat "$T/c.out")"

# 3. a lock folder without a pid (a build stopped between the two steps): taken over after ~10 s
mkdir -p "$W.lock"
t0=$(date +%s); build D 0 > "$T/d.out" 2>&1; t1=$(date +%s)
expect "a lock without a pid is taken over" yes "$(grep -q ' in D' "$T/d.out" && (( t1 - t0 >= 9 && t1 - t0 < 20 )) && echo yes || echo "$(( t1 - t0 )) s: $(cat "$T/d.out")")"

# 4. a live holder that does not finish: the waiting build gives up with a message (WORKDIR_LOCK_WAIT)
build E 30 > "$T/e.out" 2>&1 & E=$!
sleep 0.5
build F 0 2 > "$T/f.out" 2>&1; rc=$?
expect "gives up after its wait" 1 "$rc"
expect "and says so" yes "$(grep -q 'die: another omacvm build (pid [0-9]*) has used' "$T/f.out" && echo yes || cat "$T/f.out")"
expect "never took the lock" no "$(grep -q ' in F' "$T/f.out" && echo yes || echo no)"

# 5. workdir_unlock lets go of its own lock only
(
  info() { :; }; die() { exit 1; }
  source "$R/src/vm/live/workdir-lock.sh"
  workdir_unlock "$W"; [[ -d $W.lock ]] && echo kept || echo removed
) > "$T/g.out"
expect "another build's lock stays" kept "$(cat "$T/g.out")"
kill "$E" 2>/dev/null; wait 2>/dev/null

# 6. build-live.sh takes the lock before it downloads anything, and cleanup_dmg lets it go
B=$R/src/vm/live/build-live.sh
lock_line=$(grep -n '^workdir_lock "\$WORKDIR"' "$B" | cut -d: -f1)
curl_line=$(grep -n 'curl -fL' "$B" | head -1 | cut -d: -f1)
expect "build-live.sh locks before the download" yes "$([[ -n $lock_line && -n $curl_line ]] && (( lock_line < curl_line )) && echo yes || echo "lock ${lock_line:-none}, curl ${curl_line:-none}")"
expect "cleanup_dmg unlocks" yes "$(grep -q '^cleanup_dmg() {.*workdir_unlock "\$WORKDIR"' "$B" && echo yes || echo no)"
bash -n "$B"; expect "build-live.sh parses" 0 $?

(( fail )) && { echo "build-live-lock: FAILED"; exit 1; }
echo "build-live-lock: all ok"
