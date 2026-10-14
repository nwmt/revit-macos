#!/usr/bin/env bash
# Builds our shims: tools/shims/<name>/ → build/<name>/ (x86_64, llvm-mingw from scripts/get-toolchain.sh).
# Usage: ./scripts/build-shims.sh [name…]   (no names: every shim of SHIMS in scripts/lib/shims.sh)
# Sources: every *.c, *.S, *.def of tools/shims/<name>/ (ncryptshim: + build/ncryptshim/gen/ from gen_forwards.py),
# headers from tools/shims/common/. With the compiler each call builds again (seconds); the new file replaces the old
# one only after a good build, so a failed build leaves the last good one. Without it, the release that
# scripts/get-shims.sh unpacked is used, after get-shims.sh has checked that it fits these sources (it downloads the
# pinned release, or fetches the compiler when the release does not fit).
# Linked without a timestamp: the same sources give the same bytes, so a release can be checked against its tag.
# Exit: 0 every shim is in build/, 1 a build failed, 2 unknown shim.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
VKH_TAG=vulkan-sdk-1.4.363.0   # Khronos Vulkan headers for vkshim, pinned
VKH_SHA=4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
VKH="$ROOT/toolchain/vulkan-headers/include"

shim_spec() { # $1 = shim → OUT (its file in build/<shim>/), FLAGS, LIBS; 1 = no such shim
  FLAGS=(-Wno-unused-parameter); LIBS=()
  case "$1" in
    d3dwp)      OUT=d3dwp.dll;       FLAGS+=(-shared) ;;
    ncryptshim) OUT=ncrypt.dll;      FLAGS+=(-shared -municode); LIBS=(-lbcrypt -Wl,--enable-stdcall-fixup) ;;
    pdfprinter) OUT=add_printer.exe; FLAGS+=(-municode);         LIBS=(-lwinspool) ;;
    rvtfix)     OUT=rvtfix.dll;      FLAGS+=(-shared);           LIBS=(-luser32 -lole32) ;;
    svcshim)    OUT=svcshim.exe;     FLAGS+=(-municode);         LIBS=(-ladvapi32) ;;
    tlbpin)     OUT=msls31.dll;      FLAGS+=(-shared);           LIBS=(-loleaut32) ;;
    vkshim)     OUT=vulkan-1.dll;    FLAGS+=(-shared "-I$VKH");  LIBS=(-luser32) ;;
    wbemshim)   OUT=wbemshim.dll;    FLAGS+=(-shared -municode); LIBS=(-lole32 -loleaut32 -luuid -lwbemuuid) ;;
    wv2fix)     OUT=version.dll;     FLAGS+=(-shared);           LIBS=(-luser32) ;;
    *) return 1 ;;
  esac
}

vulkan_headers() { # once, into toolchain/vulkan-headers (checked by SHA-256)
  local tmp
  [ -f "$VKH/vulkan/vulkan.h" ] && return 0
  tmp="$(mktemp -d)" || return 1
  curl -fsSL --retry 3 -o "$tmp/vkh.tar.gz" "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/$VKH_TAG.tar.gz" &&
    echo "$VKH_SHA  $tmp/vkh.tar.gz" | shasum -a 256 -c --quiet - && tar -xzf "$tmp/vkh.tar.gz" -C "$tmp" &&
    mkdir -p "$ROOT/toolchain/vulkan-headers" && rm -rf "$VKH" && cp -R "$tmp/Vulkan-Headers-$VKH_TAG/include" "$ROOT/toolchain/vulkan-headers/"
  local rc=$?; rm -rf "$tmp"; return $rc
}

prebuilt() { # the pinned release's file is in build/ ($1 = shim, OUT set)
  [ "$(cat "$ROOT/build/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] && [ -f "$ROOT/build/$1/$OUT" ]
}
GOT_RELEASE=""   # get-shims.sh runs at most once per call

build_one() { # $1 = shim
  local name="$1" src="$ROOT/tools/shims/$1" out="$ROOT/build/$1" ext f files=()
  shim_spec "$name"
  if [ ! -x "$CC" ]; then
    # no compiler: the pinned release, if it fits these sources. get-shims.sh decides (source diff against the tag,
    # every shim in the package, the marker): it keeps or brings that release, or fetches the compiler
    if [ -z "$GOT_RELEASE" ]; then GOT_RELEASE=1; "$ROOT/scripts/get-shims.sh" || return 1; fi
    if [ ! -x "$CC" ]; then
      prebuilt "$name" || { echo "!! no build/$name/$OUT and no compiler"; return 1; }
      echo "prebuilt v$SHIMS_VERSION: build/$name/$OUT"; return 0
    fi
  fi
  case "$name" in
    ncryptshim) python3 -I "$src/gen_forwards.py" "$src/exports.txt" "$out/gen" >/dev/null || return 1 ;;
    vkshim) vulkan_headers || { echo "no Vulkan headers for vkshim"; return 1; } ;;
  esac
  for ext in c S def; do for f in "$src"/*."$ext" "$out/gen"/*."$ext"; do [ -f "$f" ] && files+=("$f"); done; done
  # into a folder of its own, under the final name: a DLL whose .def has no LIBRARY takes its name from the file
  rm -rf "$out/.new"; mkdir -p "$out/.new" || return 1
  if ! "$CC" -O2 -Wall "${FLAGS[@]}" "-I$ROOT/tools/shims/common" -Wl,--no-insert-timestamp -o "$out/.new/$OUT" \
       "${files[@]}" ${LIBS[@]+"${LIBS[@]}"}; then
    rm -rf "$out/.new"; echo "!! build of $name failed; build/$name/$OUT is left as it was"; return 1
  fi
  mv -f "$out/.new/$OUT" "$out/$OUT" && rmdir "$out/.new" || return 1
  rm -f "$ROOT/build/.prebuilt"   # build/ no longer holds one release only: its files are not to be taken as one
  echo "built: build/$name/$OUT ($(stat -f %z "$out/$OUT") bytes)"
}

NAMES=("$@"); [ ${#NAMES[@]} -gt 0 ] || NAMES=("${SHIMS[@]}")
for s in "${NAMES[@]}"; do shim_spec "$s" || usage_die "Unknown shim: $s. Shims: ${SHIMS[*]}"; done
lock_take "build-shims.sh ${NAMES[*]}"
rc=0
for s in "${NAMES[@]}"; do build_one "$s" || rc=1; done
exit $rc
