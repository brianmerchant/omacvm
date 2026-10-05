#!/bin/bash
# Build KosmicKrisp, Mesa's Vulkan driver on Metal, from a pinned Mesa commit:
#   app/runtime/build-kosmickrisp.sh [--archive-dir DIR] [--check | --stamp]
# Output in app/runtime/.build/kosmickrisp: libvulkan_kosmickrisp.dylib, its
# ICD file, LICENSE.mesa-kosmickrisp.txt (the licences and copyright lines of
# every Mesa file in the driver) and a stamp.
# Venus uses it instead of MoltenVK on macOS 26 and newer (it needs Metal 4);
# the runtime keeps MoltenVK for older macOS. --check only checks the build
# machine and says what is missing; --stamp prints what the build depends on
# (build-app.sh hashes it to know when to rebuild the runtime).
#
# Two Mesa builds: the first makes Mesa's OpenCL-C compiler (mesa_clc, with
# LLVM) for the driver's built-in kernels; the second builds the driver with
# that tool and without LLVM, SPIRV-Tools or zstd, so the dylib links only
# system libraries. The macos platform defines VK_USE_PLATFORM_METAL_EXT;
# without it the driver lists VK_EXT_external_memory_metal but returns NULL
# for vkGetMemoryMetalHandleEXT, which Venus needs.
# Build-time needs: Homebrew llvm, spirv-llvm-translator, spirv-tools, bison
# and pkgconf, and an SDK with Metal 4 (Xcode 26 or newer). The LLVM version
# is not pinned (it is Homebrew's); it is in the stamp, so a new one rebuilds.
set -euo pipefail

mesa_commit=e5f0687867f5c5e88619175d9b0442f8560e8d53
mesa_root="mesa-$mesa_commit"
mesa_archive_name="$mesa_root.tar.gz"
mesa_url="https://gitlab.freedesktop.org/mesa/mesa/-/archive/$mesa_commit/$mesa_archive_name"
mesa_sha256=3a6ea0ac2dd769e0e34867479fa094faa7b7f76f4c7f320318ddeb9089a1c55e

meson_root=meson-1.9.0
meson_archive_name="$meson_root.tar.gz"
meson_url="https://github.com/mesonbuild/meson/releases/download/1.9.0/$meson_archive_name"
meson_sha256=cd27277649b5ed50d19875031de516e270b22e890d9db65ed9af57d18ebc498d
ninja_archive_name=ninja-1.13.0-py3-none-macosx_10_9_universal2.whl
ninja_url="https://files.pythonhosted.org/packages/3c/74/d02409ed2aa865e051b7edda22ad416a39d81a84980f544f8de717cab133/$ninja_archive_name"
ninja_sha256=fa2a8bfc62e31b08f83127d1613d10821775a0eb334197154c4d6067b7068ff1

# Mesa's code generators: Mako (with MarkupSafe), PyYAML, packaging.
python_requirements() {
  cat <<'EOF'
setuptools==84.0.0 --hash=sha256:51a52592b3b99e102b609654876bd65f19f999935166d1352678931132b0c670
wheel==0.48.0 --hash=sha256:3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab
packaging==26.3 --hash=sha256:d7193f7c8e4e93f444fde0262bf90af30e16fa0ad0ad44cb553c87339b23cd1c
EOF
}
python_generator_requirements() {
  cat <<'EOF'
mako==1.4.3 --hash=sha256:723296007c870bfd6b3f0c3230dba7198096e5269297ebf5e4eff9e7ffa39d4f
markupsafe==3.0.4 --hash=sha256:2e9ad7dd851bf45fab9f75cbff4cb493fee9979e8d8c7c9c3ee119022518edd6
pyyaml==6.0.3 --hash=sha256:d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f
EOF
}

die() { echo "kosmickrisp-build: $*" >&2; exit 1; }
log() { echo "[kosmickrisp-build] $*"; }

archive_cache=
mode=build
while (($#)); do
  case $1 in
    --archive-dir) (($# >= 2)) || die "--archive-dir needs a directory"; archive_cache=$2; shift 2 ;;
    --check) mode=check; shift ;;
    --stamp) mode=stamp; shift ;;
    *) echo "usage: build-kosmickrisp.sh [--archive-dir DIR] [--check | --stamp]" >&2; exit 64 ;;
  esac
done

native_dir=$(cd "$(dirname "$0")" && pwd -P)
out_dir="$native_dir/.build/kosmickrisp"
stamp="$out_dir/stamp"

# The build machine: everything that is missing, in one message.
missing=()
[[ $(uname -m) == arm64 ]] || missing+=("Apple Silicon")
case $native_dir in *' '*) missing+=("a path without spaces (meson splits it): $native_dir") ;; esac
for tool in brew curl python3 shasum tar xcrun; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
brew_prefix=$(brew --prefix 2>/dev/null) || brew_prefix=/opt/homebrew
llvm_bin="$brew_prefix/opt/llvm/bin"
bison_bin="$brew_prefix/opt/bison/bin"
pkg_config="$brew_prefix/bin/pkg-config"
[[ -x $llvm_bin/llvm-config ]] || missing+=("LLVM (brew install llvm)")
[[ -x $bison_bin/bison ]] || missing+=("bison newer than 2.3 (brew install bison)")
if [[ -x $pkg_config ]]; then
  "$pkg_config" --exists LLVMSPIRVLib || missing+=("SPIRV-LLVM-Translator (brew install spirv-llvm-translator)")
  "$pkg_config" --exists SPIRV-Tools || missing+=("SPIRV-Tools (brew install spirv-tools)")
else
  missing+=("pkg-config (brew install pkgconf)")
fi
# No xcrun or no SDK: an empty version (pipefail would otherwise end the
# script here, before the list below).
sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1) || sdk_major=
[[ $sdk_major =~ ^[0-9]+$ ]] || sdk_major=
((${sdk_major:-0} >= 26)) || missing+=("the macOS 26 SDK or newer for Metal 4 (Xcode 26), have ${sdk_major:-none}")
if ((${#missing[@]})); then
  echo "kosmickrisp-build: this Mac cannot build KosmicKrisp; missing:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "kosmickrisp-build: install these, or build the runtime without OMACVM_RUNTIME_KOSMICKRISP=1 (MoltenVK only)" >&2
  exit 1
fi

# Rebuild when this script, the Mesa commit or the build-time LLVM changes.
want_stamp="$mesa_commit $(shasum -a 256 "$0" | cut -d' ' -f1) llvm-$("$llvm_bin/llvm-config" --version)"
want_stamp+=" spirv-llvm-translator-$("$pkg_config" --modversion LLVMSPIRVLib)"
case $mode in
  check) log "build machine OK (LLVM $("$llvm_bin/llvm-config" --version))"; exit 0 ;;
  stamp) echo "$want_stamp"; exit 0 ;;
esac
if [[ -f $out_dir/libvulkan_kosmickrisp.dylib && -f $out_dir/LICENSE.mesa-kosmickrisp.txt &&
      $(cat "$stamp" 2>/dev/null) == "$want_stamp" ]]; then
  log "up to date ($out_dir)"
  exit 0
fi

mkdir -p "$native_dir/.build/tmp"
work=$(mktemp -d "$native_dir/.build/tmp/kosmickrisp.XXXXXX")
cleanup() {
  if [[ -n ${OMACVM_RUNTIME_KEEP_SCRATCH:-} ]]; then
    log "kept scratch tree: $work"
  else
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

obtain() {
  local name=$1 url=$2 sha=$3 dest="$work/$1"
  if [[ -n $archive_cache && -f $archive_cache/$name ]]; then
    install -m 0644 "$archive_cache/$name" "$dest"
  else
    log "downloading $name"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
      --retry 3 --connect-timeout 20 --output "$dest" "$url"
  fi
  [[ $(shasum -a 256 "$dest" | cut -d' ' -f1) == "$sha" ]] || die "checksum mismatch: $name"
}
obtain "$mesa_archive_name" "$mesa_url" "$mesa_sha256"
obtain "$meson_archive_name" "$meson_url" "$meson_sha256"
obtain "$ninja_archive_name" "$ninja_url" "$ninja_sha256"

tar -xzf "$work/$mesa_archive_name" -C "$work"
tar -xzf "$work/$meson_archive_name" -C "$work"
mkdir -p "$work/ninja" && ditto -x -k "$work/$ninja_archive_name" "$work/ninja"
ninja_dir=$(dirname "$(find "$work/ninja" -path '*scripts/ninja' -type f | head -1)")
chmod 0755 "$ninja_dir/ninja"

log "python tools (pinned)"
python3 -m venv "$work/venv"
"$work/venv/bin/pip" -q install --disable-pip-version-check --require-hashes \
  -r <(python_requirements)
"$work/venv/bin/pip" -q install --disable-pip-version-check --require-hashes \
  --no-build-isolation --no-binary markupsafe,pyyaml -r <(python_generator_requirements)

src="$work/$mesa_root"
meson=("$work/venv/bin/python3" "$work/$meson_root/meson.py")
export PATH="$work/venv/bin:$ninja_dir:$llvm_bin:$bison_bin:$PATH" PKG_CONFIG="$pkg_config"
# The scratch path changes on every run; keep it out of the binaries.
prefix_map="-ffile-prefix-map=$work/="
export CFLAGS="$prefix_map" CXXFLAGS="$prefix_map" OBJCFLAGS="$prefix_map"
common=(--wrap-mode=nodownload -Dgallium-drivers= -Dopengl=false
  -Dgles1=disabled -Dgles2=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled
  -Dvideo-codecs= -Dtools= -Dvulkan-layers= -Dbuild-tests=false)

log "Mesa $mesa_commit: mesa_clc (build-time tool)"
"${meson[@]}" setup "$work/build-clc" "$src" --prefix="$work/clc" --buildtype=release \
  "${common[@]}" -Dplatforms= -Dvulkan-drivers= -Dllvm=enabled -Dmesa-clc=enabled \
  -Dinstall-mesa-clc=true -Dmesa-clc-bundle-headers=enabled
ninja -C "$work/build-clc"
"${meson[@]}" install -C "$work/build-clc" --no-rebuild >/dev/null
[[ -x $work/clc/bin/mesa_clc && -x $work/clc/bin/vtn_bindgen2 ]] || die "mesa_clc was not built"

# The prefix only names where Mesa would look for drirc files; a fixed one
# keeps the scratch path out of the dylib (nothing is installed there).
log "Mesa $mesa_commit: KosmicKrisp"
env PATH="$work/clc/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 \
  "${meson[@]}" setup "$work/build-kk" "$src" --prefix=/opt/omacvm-kosmickrisp --libdir=lib \
  --buildtype=release -Db_ndebug=true "${common[@]}" -Dvulkan-drivers=kosmickrisp \
  -Dplatforms=macos \
  -Dllvm=disabled -Dmesa-clc=system -Dspirv-tools=disabled -Dzstd=disabled
env PATH="$work/clc/bin:$PATH" MACOSX_DEPLOYMENT_TARGET=26.0 ninja -C "$work/build-kk"

dylib="$work/build-kk/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
[[ -f $dylib ]] || die "the driver was not built"
# Only system libraries: nothing from the build machine's Homebrew.
otool -L "$dylib" | sed -n '2,$p' | awk '{print $1}' | while read -r dep; do
  case $dep in
    @rpath/libvulkan_kosmickrisp.dylib|/usr/lib/*|/System/Library/*) ;;
    *) die "the driver links a non-system library: $dep" ;;
  esac
done
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$dylib"


# The ICD file as Mesa writes it, with the runtime's library path.
mesa_icd=$(find "$work/build-kk/src/kosmickrisp/vulkan" -maxdepth 1 -name 'kosmickrisp_mesa_icd.*json' | head -1)
[[ -f $mesa_icd ]] || die "Mesa did not write the ICD file"
python3 - "$mesa_icd" "$work/kosmickrisp_mesa_icd.json" <<'PY'
import json, sys
icd = json.load(open(sys.argv[1]))
icd["ICD"]["library_path"] = "../../../lib/libvulkan_kosmickrisp.dylib"
json.dump(icd, open(sys.argv[2], "w"), indent=4)
PY

# The licence notice: every Mesa file the driver was built from (link inputs,
# their sources and headers from ninja's deps, the kernels' sources), its
# licence and copyright lines. An unknown licence stops the build.
log "licences of the Mesa files in the driver"
python3 - "$work/build-kk" "$src" "$mesa_commit" "$work/LICENSE.mesa-kosmickrisp.txt" <<'PY'
import os, re, subprocess, sys

build, src, commit, out = sys.argv[1:5]
src = os.path.realpath(src)
target = "src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"

def ninja_tool(*args):
    return subprocess.run(["ninja", "-C", build, "-t", *args], check=True,
                          capture_output=True, text=True).stdout

inputs = ninja_tool("inputs", target).split()
objects = {p for p in inputs if p.endswith(".o")}
paths = set(inputs)
current = None
for line in ninja_tool("deps").splitlines():
    if line and not line[0].isspace():
        name = line.split(":", 1)[0]
        current = name if name in objects else None
    elif current and line.strip():
        paths.add(line.strip())
files = sorted({f for f in (os.path.realpath(os.path.join(build, p)) for p in paths)
                if f.startswith(src + os.sep) and os.path.isfile(f)})
if not files:
    sys.exit("no Mesa files found for the driver")

# SPDX expressions in these files and the licence OmacVM uses each one under.
spdx_choice = {
    "MIT": "MIT",
    "Apache-2.0 OR MIT": "MIT",
    "MIT OR Apache-2.0": "MIT",
    "Apache-2.0": "Apache-2.0",
    "BSL-1.0": "BSL-1.0",
}
comment = re.compile(r"^\s*(?:/\*+|\*+/|\*|//+|#+|;+|--)?\s?")

def clean(line):
    return comment.sub("", line).rstrip().removesuffix("*/").rstrip()

def header_block(lines):
    block = []
    for line in lines:
        block.append(clean(line))
        if "*/" in line:
            break
    while block and not block[-1]:
        block.pop()
    return "\n".join(block).strip("\n")

# The copyright holder lines of a file header: "Copyright 2020 Intel",
# "(C) Copyright ...", "SPDX-FileCopyrightText: 2014-2024 The Khronos Group
# Inc.", with year-led lines that continue one. E-mail addresses (<...>) are
# cut, the holder stays. Not licence sentences ("COPYRIGHT HOLDERS") or a
# code generator's COPYRIGHT = """ line.
marker = re.compile(r"(copyright\b|\(c\)|©)", re.I)

def holder_lines(lines):
    out, previous = [], False
    for line in lines:
        # Any comment or quoting style: "** ", "// ", "# ", a JSON string.
        raw = re.sub(r"^[^\w(©]+", "", line.strip())
        raw = re.sub(r"(\s*(\*/|-->|[\"',*]))+$", "", raw)
        c = re.sub(r"\s*<[^<>]*>", "", raw).strip()
        spdx = re.match(r"SPDX-FileCopyrightText:\s*(.+)", c, re.I)
        if spdx:
            c = spdx.group(1)
            if not marker.match(c):
                c = "Copyright " + c
        holder = re.sub(r"copyright|\(c\)|©|[\d\s,.-]", "", c, flags=re.I)
        if (marker.match(c) and re.search(r"\d{4}|©|\(c\)", c, re.I) and len(holder) >= 2
                and not re.match(r"copyright\w*\s*=", c, re.I) and '"""' not in c
                and "HOLDERS" not in raw.upper()):
            out.append(c)
            previous = True
        elif previous and re.match(r"\d{4}\b", c):
            out[-1] += ", " + c
        else:
            previous = False
    return out

groups, copyrights, verbatim, unknown, unmarked = {}, {}, {}, [], []
for path in files:
    rel = os.path.relpath(path, src)
    with open(path, encoding="utf-8", errors="replace") as f:
        head = [next(f, "") for _ in range(120)]
    text = "".join(head)
    spdx = re.search(r"SPDX-License-Identifier:\s*(.+)", text)
    if rel.startswith("src/util/blake3/"):
        lid = "BLAKE3"
    elif spdx:
        expr = clean(spdx.group(1))
        lid = spdx_choice.get(expr)
        if lid is None:
            unknown.append(f"{rel}: {expr}")
            continue
    elif "Boost Software License" in text:
        lid = "BSL-1.0"
    elif re.search(r"SGI Free Software (License )?B", text, re.I):
        lid = "SGI-B-2.0"
    elif re.search(r"GNU (Lesser |Library )?General Public", text):
        unknown.append(f"{rel}: GPL text")
        continue
    elif "Permission is hereby granted, free of charge" in text:
        lid = "MIT"
    elif ("Redistribution and use in source and binary forms" in text
          or "Permission to use, copy, modify" in text):
        lid = "own notice, quoted below"
        verbatim.setdefault(header_block(head), []).append(rel)
    elif re.search(r"public domain", text, re.I):
        lid = "public domain"
    else:
        lid = "MIT"
        unmarked.append(rel)
    groups.setdefault(lid, []).append(rel)
    for c in holder_lines(head[:60]):
        copyrights.setdefault(lid, set()).add(c)

if unknown:
    sys.exit("licences not known to build-kosmickrisp.sh:\n  " + "\n  ".join(unknown))

def licence_text(name):
    text = open(os.path.join(src, "licenses", name)).read()
    return text.split("License-Text:", 1)[-1].strip("\n")

rule = "=" * 72
parts = [f"""KosmicKrisp (lib/libvulkan_kosmickrisp.dylib in OmacVM.app's runtime)

KosmicKrisp is Mesa's Vulkan driver on Metal, built from Mesa commit
{commit} (https://gitlab.freedesktop.org/mesa/mesa).
The driver is built from {len(files)} Mesa files (sources, headers, kernels and
code generators, as the build used them). Their licences:
"""]
for lid, members in sorted(groups.items()):
    parts.append(f"- {lid}: {len(members)} files")
parts.append(f"""
Files without a licence line ({len(unmarked)}) are under Mesa's MIT licence
(docs/license.rst in Mesa).""")

def section(title, members, lid, text):
    parts.append(f"\n{rule}\n{title}\n{rule}\n")
    if members:
        parts.append("Files: " + ", ".join(members) + "\n")
    lines = sorted(copyrights.get(lid, ()))
    if lines:
        parts.append("\n".join(lines) + "\n")
    if text:
        parts.append(licence_text(text))

section("MIT", None, "MIT", "MIT")
for block, members in sorted(verbatim.items(), key=lambda kv: kv[1][0]):
    parts.append(f"\n{rule}\n{', '.join(members)}\n{rule}\n\n{block}")
if "BSL-1.0" in groups:
    section("Boost Software License 1.0", groups["BSL-1.0"], "BSL-1.0", "BSL-1.0")
if "BLAKE3" in groups:
    section("BLAKE3 1.8.2 (github.com/BLAKE3-team/BLAKE3)", groups["BLAKE3"], "BLAKE3", None)
    parts.append("BLAKE3 is licensed CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH\n"
                 "LLVM-exception; it is used here under Apache-2.0 (text below).")
if "SGI-B-2.0" in groups:
    section("SGI Free Software License B 2.0", groups["SGI-B-2.0"], "SGI-B-2.0", "SGI-B-2.0")
if "Apache-2.0" in groups or "BLAKE3" in groups:
    section("Apache License 2.0", groups.get("Apache-2.0"), "Apache-2.0", "Apache-2.0")
if "public domain" in groups:
    parts.append(f"\n{rule}\nPublic domain\n{rule}\n")
    parts.append("\n".join(groups["public domain"]))
with open(out, "w") as f:
    f.write("\n".join(parts).rstrip() + "\n")
print(f"{len(files)} files: " + ", ".join(f"{k} {len(v)}" for k, v in sorted(groups.items())))
print("without a licence line: " + ", ".join(sorted({os.path.dirname(u) for u in unmarked})))
PY

rm -rf "$out_dir"; mkdir -p "$out_dir"
install -m 0755 "$dylib" "$out_dir/libvulkan_kosmickrisp.dylib"
install -m 0644 "$work/kosmickrisp_mesa_icd.json" "$work/LICENSE.mesa-kosmickrisp.txt" "$out_dir/"
echo "$want_stamp" > "$stamp"
log "built $out_dir/libvulkan_kosmickrisp.dylib (Mesa $mesa_commit)"
