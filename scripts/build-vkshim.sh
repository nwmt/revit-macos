#!/usr/bin/env bash
# Builds tools/vkshim → build/vkshim/vulkan-1.dll (x86_64), the Vulkan fixes for Enscape. Needs scripts/get-toolchain.sh;
# fetches the Vulkan headers (Khronos, pinned by SHA-256) into toolchain/vulkan-headers once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "build-vkshim.sh"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/vkshim/vulkan-1.dll"
VKH_TAG=vulkan-sdk-1.4.363.0
VKH_SHA=4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
INC="$ROOT/toolchain/vulkan-headers/include"
if [ ! -f "$INC/vulkan/vulkan.h" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  curl -fsSL --retry 3 -o "$TMP/vkh.tar.gz" "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/$VKH_TAG.tar.gz"
  echo "$VKH_SHA  $TMP/vkh.tar.gz" | shasum -a 256 -c --quiet -
  tar -xzf "$TMP/vkh.tar.gz" -C "$TMP"
  mkdir -p "$ROOT/toolchain/vulkan-headers"; rm -rf "$ROOT/toolchain/vulkan-headers/include"
  cp -R "$TMP/Vulkan-Headers-$VKH_TAG/include" "$ROOT/toolchain/vulkan-headers/"
fi
SRC="$ROOT/tools/vkshim"; OUT="$ROOT/build/vkshim"; mkdir -p "$OUT"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -I"$INC" \
  -o "$OUT/vulkan-1.dll" "$SRC/vkshim.c" "$SRC/vulkan-1.def" -luser32
echo "built: $OUT/vulkan-1.dll ($(stat -f %z "$OUT/vulkan-1.dll") bytes)"
"$ROOT/toolchain/llvm-mingw/bin/llvm-objdump" -p "$OUT/vulkan-1.dll" | awk '/DLL Name/{print "   import:", $3}'
