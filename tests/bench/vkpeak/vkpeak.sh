#!/bin/bash
# Vulkan compute peak with vkpeak (github.com/nihui/vkpeak, MIT), the same
# version on the Mac and in a VM. One JSON line per run.
#   vkpeak.sh [--runs N] [--scenarios LIST] [--device N] [OUT.jsonl]
# The Mac: the release's macOS binary (MoltenVK built in), checked against its
# sha256. Linux (arm64 VMs): built from the same tag's source into
# ~/.cache/omacvm-bench (needs git, cmake and a C++ compiler; on Arch:
# pacman -S --needed git cmake base-devel).
# No Vulkan device, or only a CPU one (llvmpipe, lavapipe, SwiftShader): one
# line with "not_available" and the reason, exit 0. That is a result too.
set -uo pipefail
VER=20260527
COMMIT=f108eb11d467eb3d5cdd472f8e080818a117a752   # tag 20260527
MAC_ZIP_SHA256=3bd6ffe4117628c911b76a4e64849b42932823e85e34d6071aa76d8cf674817c
RUNS=3; DEV=0
SCEN="fp32-scalar,fp32-vec4,fp16-scalar,fp16-vec4,int32-scalar,int32-vec4"
while [[ ${1:-} == --* ]]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --scenarios) SCEN=$2; shift 2 ;;
    --device) DEV=$2; shift 2 ;;
    *) echo "vkpeak.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
OUT=${1:-/dev/null}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/omacvm-bench/vkpeak-$VER
say() { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
line() { echo "$1" | tee -a "$OUT"; }
na() {   # reason
  line "{\"test\":\"vkpeak\",\"version\":\"$VER\",\"host\":\"$(hostname -s)\",\"os\":\"$(uname -s)\",\"not_available\":\"$1\",\"at\":\"$(date -u +%FT%TZ)\"}"
  exit 0
}

get_mac() {
  local zip=$CACHE/vkpeak-$VER-macos.zip
  [[ -x $CACHE/vkpeak-$VER-macos/vkpeak ]] && { BIN=$CACHE/vkpeak-$VER-macos/vkpeak; return 0; }
  mkdir -p "$CACHE"
  curl -fsSL -o "$zip" "https://github.com/nihui/vkpeak/releases/download/$VER/vkpeak-$VER-macos.zip" || return 1
  [[ $(shasum -a 256 "$zip" | cut -d' ' -f1) == "$MAC_ZIP_SHA256" ]] || { echo "vkpeak.sh: checksum mismatch" >&2; rm -f "$zip"; return 1; }
  unzip -q -o "$zip" -d "$CACHE" && BIN=$CACHE/vkpeak-$VER-macos/vkpeak
}
get_linux() {
  BIN=$CACHE/build/vkpeak
  [[ -x $BIN ]] && return 0
  local t
  for t in git cmake c++ make; do command -v $t >/dev/null || { echo "vkpeak.sh: $t is missing (pacman -S --needed git cmake base-devel)" >&2; return 1; }; done
  say "building vkpeak $VER (a few minutes, once)"
  rm -rf "$CACHE/src" "$CACHE/build"; mkdir -p "$CACHE"
  git -c advice.detachedHead=false clone -q https://github.com/nihui/vkpeak "$CACHE/src" &&
    git -C "$CACHE/src" -c advice.detachedHead=false checkout -q "$COMMIT" &&
    git -C "$CACHE/src" submodule -q update --init --depth 1 ncnn &&
    git -C "$CACHE/src/ncnn" submodule -q update --init --depth 1 glslang &&
    cmake -S "$CACHE/src" -B "$CACHE/build" -DCMAKE_BUILD_TYPE=Release >"$CACHE/build.log" 2>&1 &&
    cmake --build "$CACHE/build" -j "$(nproc)" >>"$CACHE/build.log" 2>&1 ||
    { echo "vkpeak.sh: build failed, see $CACHE/build.log" >&2; return 1; }
}

case $(uname -s) in
  Darwin) get_mac || na "could not get vkpeak $VER for macOS" ;;
  Linux)
    get_linux || na "could not build vkpeak $VER"
    if command -v vulkaninfo >/dev/null; then
      types=$(vulkaninfo --summary 2>/dev/null | sed -n 's/.*deviceType *= *//p' | sort -u | tr '\n' ' ')
      [[ -z $types ]] && na "no Vulkan device"
      [[ $types == "PHYSICAL_DEVICE_TYPE_CPU " ]] && na "CPU Vulkan only (no GPU device)"
    fi ;;
  *) na "unsupported OS $(uname -s)" ;;
esac

for ((i = 1; i <= RUNS; i++)); do
  say "vkpeak $SCEN, run $i/$RUNS"
  start=$(date +%s)
  raw=$("$BIN" "$DEV" "$SCEN" 2>&1)
  rc=$?
  secs=$(($(date +%s) - start))
  device=$(sed -n 's/^device *= *//p' <<<"$raw" | head -1)
  driver=$(sed -n 's/^driver *= *//p' <<<"$raw" | head -1)
  [[ -n $device ]] || na "no Vulkan device (vkpeak exit $rc)"
  shopt -s nocasematch
  [[ $device =~ llvmpipe|lavapipe|swiftshader|softpipe ]] && { shopt -u nocasematch; na "CPU Vulkan only ($device)"; }
  shopt -u nocasematch
  # "fp32-scalar  = 15760.08 GFLOPS" -> "fp32-scalar":15760.08
  vals=$(sed -n 's/^\([a-z0-9-]*\) *= *\([0-9.]*\) *[A-Z]*$/"\1":\2/p' <<<"$raw" | paste -sd, -)
  best() { sed -n "s/^$1-[a-z0-9]* *= *\([0-9.]*\) .*/\1/p" <<<"$raw" | sort -g | tail -1; }
  fp32=$(best fp32); fp16=$(best fp16); int32=$(best int32)
  line "{\"test\":\"vkpeak\",\"version\":\"$VER\",\"host\":\"$(hostname -s)\",\"os\":\"$(uname -s)\",\"run\":$i,\"device\":\"$device\",\"driver\":\"$driver\",\"fp32_gflops\":${fp32:-null},\"fp16_gflops\":${fp16:-null},\"int32_giops\":${int32:-null},\"scenarios\":{$vals},\"seconds\":$secs,\"at\":\"$(date -u +%FT%TZ)\"}"
done
