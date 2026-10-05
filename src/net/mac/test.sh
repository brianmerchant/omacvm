#!/bin/bash
# omacvm-netd's offline tests: it builds without warnings, and its time limits
# on vmnet, back-off, bridge check and failure handling hold (test-netd.c, with
# vmnet replaced). No root, no VM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FW=(-framework vmnet -framework Security -framework CoreFoundation -lbsm)
xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 -o "$T/omacvm-netd" "$HERE/omacvm-netd.c" "${FW[@]}"
echo "ok   omacvm-netd builds without warnings"
xcrun clang -O1 -g -Wall -Wno-unused-function -fsanitize=address,undefined -mmacosx-version-min=14.0 \
  -o "$T/test-netd" "$HERE/test-netd.c" "${FW[@]}"
# A user's process named like macOS's vmnet service (the daemon must not watch it).
echo '#include <unistd.h>
int main(void) { sleep(120); return 0; }' | xcrun clang -x c -o "$T/InternetSharing" -
"$T/InternetSharing" & FAKE=$!; disown "$FAKE"
trap 'kill "$FAKE" 2>/dev/null; rm -rf "$T"' EXIT
NETD_STATE=$T/state NETD_FAKE_SHARING=$FAKE "$T/test-netd" 2>"$T/log" || { cat "$T/log" >&2; exit 1; }

# The app's button: install.sh's root script and its arguments reach /bin/sh
# through osascript unchanged (here without the password dialog).
eval "$(sed -n '/^shq() /p; /^root_cmd() /p' "$HERE/install.sh")"
args=("$T/args" "it's" $'two\nlines' '$(id) `id` "q" \\ ;&|' "")
cmd=$(root_cmd 'f=$1; shift; printf "[%s]\n" "$@" > "$f"' _ "${args[@]}")
/usr/bin/osascript - "$cmd" <<'AS' >/dev/null
on run argv
  do shell script (item 1 of argv)
end run
AS
[[ $(cat "$T/args") == "$(printf '[%s]\n' "${args[@]:1}")" ]] && echo "ok   password dialog path: the root script's arguments arrive unchanged" ||
  { echo "FAIL password dialog path: got"; cat "$T/args"; exit 1; }
