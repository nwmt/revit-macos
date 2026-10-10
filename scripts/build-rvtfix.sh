#!/usr/bin/env bash
# Builds tools/rvtfix → build/rvtfix/rvtfix.dll (x86_64). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/rvtfix/rvtfix.dll"
SRC="$ROOT/tools/rvtfix"; OUT="$ROOT/build/rvtfix"; mkdir -p "$OUT"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -o "$OUT/rvtfix.dll" "$SRC/rvtfix.c" -luser32 -lole32
echo "built: $OUT/rvtfix.dll ($(stat -f %z "$OUT/rvtfix.dll") bytes)"
