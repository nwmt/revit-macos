#!/usr/bin/env bash
# Builds tools/ncrypt-shim → build/ncrypt-shim/ncrypt.dll (x86_64). Needs scripts/get-toolchain.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/ncrypt-shim/ncrypt.dll"
SRC="$ROOT/tools/ncrypt-shim"; OUT="$ROOT/build/ncrypt-shim"; mkdir -p "$OUT"
python3 "$SRC/gen_forwards.py"
"$CC" -shared -O2 -Wall -Wno-unused-parameter -municode \
  -o "$OUT/ncrypt.dll" "$SRC/ncrypt_shim.c" "$SRC/forwards_table.c" "$SRC/forwards.S" "$SRC/ncrypt.def" \
  -lbcrypt -Wl,--enable-stdcall-fixup
echo "built: $OUT/ncrypt.dll ($(stat -f %z "$OUT/ncrypt.dll") bytes)"
"$ROOT/toolchain/llvm-mingw/bin/llvm-objdump" -p "$OUT/ncrypt.dll" | awk '/DLL Name/{print "   import:", $3}'
