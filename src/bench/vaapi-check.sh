#!/bin/bash
# Video decoding through VA-API (OmacVM.app: the Mac's media engine) against
# FFmpeg's own software decoder, frame by frame. Run in the VM, as any user:
#   vaapi-check.sh [FILE...]
# Without files it makes short test clips (H.264, VP9, HEVC; 1080p, B-frames,
# VP9 alt-ref frames). Prints one line per file: frames compared and how many
# are bit-identical. 8-bit files are also read out in the other YUV layout
# (NV12 <-> I420, which OmacVM's driver shim does on the CPU). Needs ffmpeg
# (and vainfo for the list of decoders).
set -euo pipefail
dev=${VAAPI_DEVICE:-/dev/dri/renderD128}
# OmacVM.app's driver shim (NV12 surfaces), as in the desktop session.
if [[ -z ${LIBVA_DRIVER_NAME:-} && -f /usr/local/lib/dri/omacvm_drv_video.so ]]; then
  export LIBVA_DRIVER_NAME=omacvm LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
command -v vainfo >/dev/null && vainfo --display drm --device "$dev" 2>/dev/null |
  sed -n 's/^[[:space:]]*VAProfile\([A-Za-z0-9]*\)[[:space:]]*:[[:space:]]*VAEntrypointVLD$/decoder: \1/p'

files=("$@")
if ((${#files[@]} == 0)); then
  src=(-f lavfi -i "testsrc2=size=1920x1080:rate=30,noise=alls=8:allf=t" -t 3 -pix_fmt yuv420p)
  ffmpeg -nostdin -hide_banner -loglevel error -y "${src[@]}" -c:v libx264 -preset medium "$tmp/h264.mp4"
  files+=("$tmp/h264.mp4")
  for pass in 1 2; do   # two passes: libvpx makes hidden alt-ref frames
    out=/dev/null; [[ $pass == 2 ]] && out=$tmp/vp9.webm
    ffmpeg -nostdin -hide_banner -loglevel error -y "${src[@]}" -c:v libvpx-vp9 -b:v 3M \
      -pass $pass -passlogfile "$tmp/vp9" -auto-alt-ref 1 -lag-in-frames 25 -cpu-used 4 -f webm "$out"
  done
  files+=("$tmp/vp9.webm")
  if [[ $(ffmpeg -hide_banner -encoders 2>/dev/null) == *libx265* ]]; then
    ffmpeg -nostdin -hide_banner -loglevel error -y "${src[@]}" -c:v libx265 -preset fast \
      -x265-params log-level=error "$tmp/hevc.mp4"
    files+=("$tmp/hevc.mp4")
  fi
fi

# Frames of $1 and $2 (framemd5 files) that are bit-identical.
same() {
  paste <(grep -v '^#' "$1" | awk -F, '{ print $NF }') <(grep -v '^#' "$2" | awk -F, '{ print $NF }') |
    awk '$1 == $2' | wc -l
}
hwdl() {   # hwdl FILE FORMAT OUT: VA-API decode, read out as FORMAT
  ffmpeg -nostdin -hide_banner -loglevel error -y -hwaccel vaapi -hwaccel_device "$dev" \
    -hwaccel_output_format vaapi -i "$1" -frames 600 -vf hwdownload,format=$2 -f framemd5 "$3"
}

fail=0
for f in "${files[@]}"; do
  # The frames are read in the surfaces' own layout: NV12 with OmacVM's shim,
  # I420 with Mesa's driver alone (FFmpeg picks it when offered; converting
  # on the way out goes through the GPU and is not what is checked here).
  # 10-bit video comes out as P010.
  fmt=nv12
  [[ ${LIBVA_DRIVER_NAME:-} == omacvm ]] || fmt=yuv420p
  [[ $(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$f") == *10* ]] && fmt=p010le
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -frames 600 -pix_fmt $fmt -f framemd5 "$tmp/sw.md5"
  if ! hwdl "$f" $fmt "$tmp/hw.md5"; then
    echo "$(basename "$f"): VA-API decoding failed"; fail=1; continue
  fi
  n=$(grep -vc '^#' "$tmp/sw.md5")
  s=$(same "$tmp/sw.md5" "$tmp/hw.md5")
  echo "$(basename "$f"): $s of $n frames bit-identical"
  ((s == n)) || fail=1
  [[ $fmt == p010le ]] && continue
  # The other layout: a lossless reshuffle, so bit-identical too.
  other=yuv420p; [[ $fmt == yuv420p ]] && other=nv12
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -frames 600 -pix_fmt $other -f framemd5 "$tmp/sw2.md5"
  if hwdl "$f" $other "$tmp/hw2.md5"; then
    s=$(same "$tmp/sw2.md5" "$tmp/hw2.md5")
    echo "$(basename "$f") as $other: $s of $n frames bit-identical"
  else
    s=0; echo "$(basename "$f") as $other: VA-API read-out failed"
  fi
  ((s == n)) || fail=1
done
exit $fail
