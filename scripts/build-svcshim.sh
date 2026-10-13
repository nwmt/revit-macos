#!/usr/bin/env bash
# Builds tools/svcshim → build/svcshim/svcshim.exe (x86_64, no .NET). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "build-svcshim.sh"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/svcshim/svcshim.exe"
SRC="$ROOT/tools/svcshim"; OUT="$ROOT/build/svcshim"; mkdir -p "$OUT"
"$CC" -O2 -Wall -Wno-unused-parameter -municode -o "$OUT/svcshim.exe" "$SRC/svcshim.c" -ladvapi32
echo "built: $OUT/svcshim.exe ($(stat -f %z "$OUT/svcshim.exe") bytes)"
"$ROOT/toolchain/llvm-mingw/bin/llvm-objdump" -p "$OUT/svcshim.exe" | awk '/DLL Name/{print "   import:", $3}'
