#!/bin/bash
# Shared by the final-round runners (sourced, not run). macOS's bash 3.2.
# Every result is one JSON line in $OUT with the fairness facts next to it,
# so a number that was taken on a busy or charging Mac shows it.

FR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$FR/../../.." && pwd)
GLMARK2_VERSION=${GLMARK2_VERSION:-2023.01}   # the same glmark2 in every VM
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
jstr() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

battery() {   # key -> value from AppleSmartBattery (Yes/No/number)
  ioreg -rw0 -c AppleSmartBattery | tr ',' '\n' | sed -n "s/.*\"$1\" *= *\([A-Za-z0-9]*\).*/\1/p" | head -1
}
# The built-in display's level, read only (the user sets it; never changed
# here). Built once at load time: brightness() runs in subshells.
BRIGHT=$(mktemp -d)/brightness
swiftc -O -o "$BRIGHT" "$REPO/src/bench/brightness.swift" 2>/dev/null || BRIGHT=""
brightness() { if [ -n "$BRIGHT" ]; then "$BRIGHT" 2>/dev/null || echo null; else echo null; fi; }

# Other work on the Mac: VM processes other than the one under test, Claude
# agents, the bench lock. Prints a JSON object; busy=true if anything runs.
busy_check() {   # [pattern of the VM under test, kept out of the count]
  local keep=${1:-NONE} vms agents lock load
  vms=$(ps -axo pid=,comm= | grep -E 'qemu-system-aarch64|prl_vm_app|vmware-vmx|QEMULauncher|com.apple.Virtualization.VirtualMachine' |
        grep -Ev -- "$keep" | grep -c .)
  agents=$(pgrep -fi '(^|/)claude( |$)' | grep -c .)
  lock=$(cat "$HOME/.omacvm-bench.lock/owner" 2>/dev/null)
  load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
  printf '{"other_vms":%s,"claude_processes":%s,"bench_lock":%s,"load1":%s,"busy":%s}' \
    "$vms" "$agents" "$(jstr "$lock")" "$load" "$([ "$vms" -gt 0 ] || [ "$agents" -gt 1 ] && echo true || echo false)"
}

# Facts about the Mac for each line.
mac_meta() {
  local disp
  disp=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution:|UI Looks like:/ {gsub(/^ +/, "", $2); printf "%s; ", $2}')
  printf '{"mac":%s,"macos":%s,"display":%s,"brightness":%s,"charging":%s,"external_power":%s,"battery_pct":%s}' \
    "$(jstr "$(sysctl -n hw.model)")" "$(jstr "$(sw_vers -productVersion) ($(sw_vers -buildVersion))")" "$(jstr "$disp")" \
    "$(brightness)" "$(jstr "$(battery IsCharging)")" "$(jstr "$(battery ExternalConnected)")" "$(battery CurrentCapacity)"
}

# Refuse unless the Mac is as agreed for the final round: on the charger and
# not charging (SystemPowerIn is the whole Mac then), nothing else busy.
# FINAL_ROUND_ALLOW_BUSY=1: run anyway, lines marked "preliminary".
PRELIM=false
preflight() {   # [VM pattern]
  local b
  [ "$(battery IsCharging)" = "No" ] || die "the Mac is charging: wait until it is full (or not charging), then run again"
  b=$(busy_check "${1:-}")
  case $b in
    *'"busy":true'*)
      if [ "${FINAL_ROUND_ALLOW_BUSY:-0}" = 1 ]; then PRELIM=true; say "busy Mac, numbers marked preliminary: $b"
      else die "the Mac is not quiet: $b (quit the other VMs and agents, or FINAL_ROUND_ALLOW_BUSY=1 for a preliminary run)"; fi ;;
  esac
}

# rec TARGET TEST JSON: one line in $OUT, the result plus the facts.
rec() {
  printf '{"target":"%s","test":"%s","preliminary":%s,"result":%s,"mac_state":%s,"quiet":%s,"at":"%s"}\n' \
    "$1" "$2" "$PRELIM" "$3" "$(mac_meta)" "$(busy_check "${KEEP_VM:-NONE}")" "$(date -u +%FT%TZ)" | tee -a "$OUT"
}
