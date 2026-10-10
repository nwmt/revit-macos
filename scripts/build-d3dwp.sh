#!/usr/bin/env bash
# Builds tools/d3d11-warp-shim → build/d3dwp/d3dwp.dll (x86_64). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
[ -x "$CC" ] || "$ROOT/scripts/get-toolchain.sh"
SRC="$ROOT/tools/d3d11-warp-shim"; OUT="$ROOT/build/d3dwp"; mkdir -p "$OUT"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -o "$OUT/d3dwp.dll" "$SRC/d3dwp.c" "$SRC/d3dwp.def"
echo "built: $OUT/d3dwp.dll ($(stat -f %z "$OUT/d3dwp.dll") bytes)"
"$ROOT/toolchain/llvm-mingw/bin/llvm-objdump" -p "$OUT/d3dwp.dll" | awk '/DLL Name/{print "   import:", $3} /^\s+[0-9]+ +[0-9]+ +D3D/{print "   export:", $NF}'
