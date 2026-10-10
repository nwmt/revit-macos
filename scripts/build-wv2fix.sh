#!/usr/bin/env bash
# Builds tools/wv2fix → build/wv2fix/version.dll (x86_64, loaded by msedgewebview2.exe). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
[ -x "$CC" ] || "$ROOT/scripts/get-toolchain.sh"
SRC="$ROOT/tools/wv2fix"; OUT="$ROOT/build/wv2fix"; mkdir -p "$OUT"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -o "$OUT/version.dll" "$SRC/wv2fix.c" "$SRC/version.def" -luser32
echo "built: $OUT/version.dll ($(stat -f %z "$OUT/version.dll") bytes)"
