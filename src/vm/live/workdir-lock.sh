# workdir-lock.sh: one build-live.sh at a time per work folder (sourced by it).
# Two `omacvm build` runs at once shared ~/Library/Caches/omacvm/build-live:
# both downloaded into the same TryOmarchy-*.dmg.part, the first one moved it
# away and the second stopped with "mv: ... No such file or directory"; both
# also wrote the same rootfs.ext4 (seen 2026-10-08: UTM, Parallels and Fusion
# built side by side). Now the second one waits until the first is done.
# The lock is a folder next to the work folder with the holder's pid in it; a
# lock whose process is gone (a crash, Ctrl-C) is taken over.
#   workdir_lock DIR      take it; waits up to WORKDIR_LOCK_WAIT s (3600)
#   workdir_unlock DIR    let it go (only this process's own)
# Needs log-style functions info and die from the caller.

workdir_lock() {
  local lock="$1.lock" pid="" waited=0 nopid=0
  mkdir -p "$(dirname "$1")"
  while ! mkdir "$lock" 2>/dev/null; do
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -z $pid ]]; then
      # just made by another build that writes its pid next; none after 10 s: left behind
      nopid=$((nopid + 1))
      if (( nopid > 10 )); then rm -rf "$lock"; continue; fi
    elif ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"; continue   # its build is gone
    fi
    if (( waited == 0 )); then
      info "another omacvm build is making its live installer in $1 (pid ${pid:-?}): waiting until it is done"
    fi
    if (( waited >= ${WORKDIR_LOCK_WAIT:-3600} )); then
      die "another omacvm build (pid ${pid:-?}) has used $1 for $((waited / 60)) min; when it has ended, run omacvm again"
    fi
    sleep 1; waited=$((waited + 1))
  done
  echo $$ > "$lock/pid"
}

workdir_unlock() {
  [[ $(cat "$1.lock/pid" 2>/dev/null || true) == "$$" ]] && rm -rf "$1.lock"
  return 0
}
