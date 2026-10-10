#!/usr/bin/env bash
# Builds tools/wbem-shim → build/wbem-shim/wbemshim.dll (x86_64). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/wbem-shim/wbemshim.dll"
OUT="$ROOT/build/wbem-shim"; mkdir -p "$OUT"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -municode -o "$OUT/wbemshim.dll" \
  "$ROOT/tools/wbem-shim/wbem_shim.c" "$ROOT/tools/wbem-shim/wbemshim.def" -lole32 -loleaut32 -luuid -lwbemuuid
echo "built: $(ls "$OUT")"
