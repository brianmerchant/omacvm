#!/bin/bash
# src/vm/progress.sh on pacman's own output (as pacstrap and omarchy-mac print
# it without a terminal): the progress lines the app reads, the raw lines kept.
# No VM; macOS's bash and awk (the VM has gawk: both must work). Exit 0 = pass.
set -euo pipefail
cd "$(dirname "$0")/../.."
source src/vm/progress.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

cat > "$t/in" <<'LOG'
:: Synchronizing package databases...
 core downloading...
 extra downloading...
OMACVM_CACHE 1000
resolving dependencies...

Package (3)        New Version  Net Change  Download Size

extra/liblqr       0.4.3-1        0.09 MiB       0.03 MiB
extra/imagemagick  7.1.2.32-1    26.45 MiB       7.96 MiB
extra/mesa         1:26.2.4-1    40.00 MiB      12.00 MiB

Total Download Size:    20.00 MiB
Total Installed Size:  66.54 MiB

:: Proceed with installation? [Y/n]
:: Retrieving packages...
 liblqr-0.4.3-1-aarch64 downloading...
OMACVM_CACHE 5243880
 mesa-1:26.2.4-1-aarch64 downloading...
 ttf-font-awesome-7.1.0-1-any downloading...
OMACVM_CACHE 20972520
checking keyring...
OMACVM_CACHE 20972520
:: Processing package changes...
installing liblqr...
@ESC@[1;32m==>@ESC@[0m Building image from preset
installing mesa...
upgrading imagemagick...
LOG
sed -i '' "s/@ESC@/$(printf '\033')/g" "$t/in"
pac_progress "$t/raw" < "$t/in" > "$t/out"
grep -v '^| ' "$t/out" > "$t/app"
check "database downloads are not packages" "! grep -q '\"now\": \"core\"' '$t/app'"
check "download: no bytes before the cache grows" "grep -q '\"phase\": \"download\", \"now\": \"liblqr\", \"n\": 1, \"of\": 3}' '$t/app'"
check "download: bytes from the cache, counted from where it began" "grep -q '\"now\": \"liblqr\", \"n\": 1, \"of\": 3, \"done\": 5242880, \"total\": 20971520' '$t/app'"
check "epoch in the version" "grep -q '\"now\": \"mesa\", \"n\": 2' '$t/app'"
check "any-arch package" "grep -q '\"now\": \"ttf-font-awesome\", \"n\": 3' '$t/app'"
check "no download lines once checking" "[[ \$(grep -c 'download' '$t/app') == 5 ]]"
check "install count" "grep -q '\"phase\": \"install\", \"now\": \"liblqr\", \"n\": 1, \"of\": 3}' '$t/app' && grep -q '\"now\": \"imagemagick\", \"n\": 3, \"of\": 3}' '$t/app'"
check "==> lines plain, colours out" "grep -qx '==> Building image from preset' '$t/app'"
check "raw lines kept, cache lines not" "[[ \$(wc -l < '$t/raw') -eq \$(grep -vc '^OMACVM_CACHE' '$t/in') ]] && ! grep -q OMACVM_CACHE '$t/raw'"
check "raw lines marked for the log" "grep -qx '| installing mesa...' '$t/out'"
# A name with odd characters cannot break the JSON.
printf 'Packages (1) x\n:: Retrieving packages...\n a"b\\\\c-1-1-any downloading...\n' | pac_progress /dev/null | grep -v '^| ' > "$t/odd"
check "odd name sanitised" "grep -q '\"now\": \"abc\"' '$t/odd' && python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' '$t/odd'"
python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]' "$t/app" && echo "ok   every progress line is JSON" || { echo "FAIL JSON"; fails=$((fails + 1)); }
(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
