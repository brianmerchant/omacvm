#!/bin/bash
# omacvm-vdecd (Chromium video) comes back by itself: a GPU that is not usable
# at boot is tried again (exit 4, restarts that back off, no storm); a pacman
# update builds it again when FFmpeg's soname changed and starts it when it
# was down; omacvm check says why it is down. No VM needed: vdecd.sh runs with
# ldd, systemctl, journalctl, cc and pkg-config replaced.
#   src/tests/vdecd-down.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
G=$R/src/vdec/guest
T=$(mktemp -d "${TMPDIR:-/tmp}/vdecd-down.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
has() {   # WHAT FILE TEXT
  if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: '$3' not in ${2#"$R"/}"; fail=1; fi
}

# ---------- the stand-ins ----------
# LDD: what ldd prints; STATE: active|auto-restart|dead; RESULT: systemd's
# Result; JOURNAL: the unit's lines this boot; CC: ok|fail. CALLS: what ran.
mkdir -p "$T/bin"
cat > "$T/bin/ldd" <<'EOF'
#!/bin/bash
printf '%s\n' "$LDD"
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "is-active -q") [[ $STATE == active ]] ;;
  "show -p") [[ $3 == SubState ]] && echo "$STATE"; [[ $3 == Result ]] && echo "$RESULT"; exit 0 ;;
  *) echo "systemctl $*" >> "$CALLS" ;;
esac
EOF
cat > "$T/bin/journalctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$JOURNAL"
EOF
cat > "$T/bin/cc" <<'EOF'
#!/bin/bash
echo "cc" >> "$CALLS"
[[ $CC == ok ]] || exit 1
while (( $# )); do [[ $1 == -o ]] && echo new > "$2"; shift; done
EOF
cat > "$T/bin/pkg-config" <<'EOF'
#!/bin/bash
echo -lavcodec
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" CALLS=$T/calls
export OMACVM_VDECD_BIN=$T/omacvm-vdecd OMACVM_VDECD_UNIT=$T/omacvm-vdecd.service OMACVM_VDECD_LOG=$T/build.log
gone="	libavcodec.so.62 => not found"
fine="	libavcodec.so.63 => /usr/lib/libavcodec.so.63 (0x0000)"
gpu="vdecd: the GPU is not usable (GBM on /dev/dri/renderD128 failed): apps decode on the CPU, trying again"

why() {   # LDD STATE RESULT JOURNAL
  LDD=$1 STATE=$2 RESULT=$3 JOURNAL=$4 "$G/vdecd.sh" why
}
hook() {   # LDD STATE CC -> what ran, the binary, what it said
  : > "$CALLS"; echo old > "$OMACVM_VDECD_BIN"
  local said; said=$(LDD=$1 STATE=$2 RESULT=success JOURNAL="" CC=$3 "$G/vdecd.sh" hook)
  echo "$(tr '\n' ' ' < "$CALLS")| $(cat "$OMACVM_VDECD_BIN") | $said"
}

# ---------- why it is down (omacvm check, control centre) ----------
expect "why: a new FFmpeg, the old soname gone" \
  "built for an FFmpeg that is gone (libavcodec.so.62 missing): omacvm apply" "$(why "$gone" dead exit-code "")"
expect "why: GPU not usable, retrying" "${gpu#vdecd: }" \
  "$(why "$fine" auto-restart exit-code "vdecd: ready: H.264 VP9
$gpu")"
expect "why: no decoding offered (exit 0)" "VA-API offers no H.264, HEVC or VP9 decoding: exiting, apps decode on the CPU" \
  "$(why "$fine" dead success "vdecd: VA-API offers no H.264, HEVC or VP9 decoding: exiting, apps decode on the CPU")"
expect "why: watchdog, restarting" "it stopped answering (killed by the watchdog); starts again by itself" \
  "$(why "$fine" auto-restart watchdog "vdecd: ready: H.264 VP9")"
expect "why: crashed" "it crashed (journalctl -u omacvm-vdecd)" "$(why "$fine" dead signal "vdecd: ready: H.264 VP9")"
expect "why: gave up" "it failed too often: systemctl restart omacvm-vdecd" "$(why "$fine" failed start-limit-hit "")"
expect "why: nothing known" "not running (journalctl -u omacvm-vdecd)" "$(why "$fine" dead success "")"

# ---------- the pacman hook ----------
: > "$CALLS"; echo old > "$OMACVM_VDECD_BIN"
LDD=$gone STATE=dead CC=ok "$G/vdecd.sh" hook
expect "hook: feature off (no unit): nothing" "" "$(cat "$CALLS")"
touch "$OMACVM_VDECD_UNIT"
expect "hook: running, libraries there: left alone" "| old | " "$(hook "$fine" active ok)"
expect "hook: down, libraries there: started again" \
  "systemctl restart --no-block omacvm-vdecd.service | old | " "$(hook "$fine" auto-restart ok)"
expect "hook: soname gone, running: built again, not restarted" \
  "cc | new | omacvm-vdecd: built again (libavcodec.so.62 is gone)" "$(hook "$gone" active ok)"
expect "hook: soname gone, down: built again and started" \
  "cc systemctl restart --no-block omacvm-vdecd.service | new | omacvm-vdecd: built again (libavcodec.so.62 is gone)" \
  "$(hook "$gone" dead ok)"
expect "hook: does not build: old binary kept, says so" \
  "cc systemctl restart --no-block omacvm-vdecd.service | old | omacvm-vdecd: does not build against the new libraries (log: $T/build.log): omacvm apply" \
  "$(hook "$gone" dead fail)"

# ---------- the pieces fit ----------
U=$G/omacvm-vdecd.service
has "unit: restarts on failure" "$U" "Restart=on-failure"
has "unit: exit 3 (module from another build) stays down" "$U" "RestartPreventExitStatus=3"
expect "unit: exit 4 (GPU) is restarted" "" "$(grep '^RestartPreventExitStatus=.*\b4\b' "$U")"
# systemd's delays: RestartSec * (max/RestartSec)^(n/steps), capped at max.
# Fewer than StartLimitBurst (5) starts in StartLimitIntervalSec (10 s): it
# never gives up, and a GPU that stays broken costs one try every 2 minutes.
sec=$(sed -n 's/^RestartSec=//p' "$U"); steps=$(sed -n 's/^RestartSteps=//p' "$U")
max=$(sed -n 's/^RestartMaxDelaySec=\([0-9]*\)min$/\1/p' "$U")
starts=$(awk -v s="$sec" -v n="$steps" -v m="$((max * 60))" 'BEGIN {
  t = 0; c = 1; for (i = 0; i < 20; i++) { d = s * (m / s) ^ (i / n); if (d > m) d = m; t += d; if (t <= 10) c++ }
  print (c < 5 ? "ok" : c) "," (d == m ? "capped" : d) }')
expect "unit: backoff 2 s -> 2 min, under the start limit" "2,ok,capped" "$sec,$starts"
has "daemon: GPU not usable = exit 4" "$G/omacvm-vdecd.c" "return 4;"
H=$G/95-omacvm-vdecd.hook
has "hook: on FFmpeg updates" "$H" "Target = ffmpeg"
has "hook: on Mesa updates" "$H" "Target = mesa"
# apply copies src/ to /usr/local/share/omacvm: the hook's path is that copy.
expect "hook: runs vdecd.sh where apply puts it" "/usr/local/share/omacvm/vdec/guest/vdecd.sh hook" \
  "$(sed -n 's/^Exec = //p' "$H")"
x=1; [[ -x $G/vdecd.sh ]] && x=0; expect "vdecd.sh is executable" 0 $x
has "install.sh: installs the hook" "$G/install.sh" "/etc/pacman.d/hooks/95-omacvm-vdecd.hook"
expect "install.sh off: removes the hook" 1 "$(sed -n '/^if \[\[ \$ON == off \]\]/,/^fi$/p' "$G/install.sh" | grep -c '95-omacvm-vdecd.hook')"
has "check.sh: asks vdecd.sh why" "$R/src/guest/check.sh" "/usr/local/share/omacvm/vdec/guest/vdecd.sh why"

exit $fail
