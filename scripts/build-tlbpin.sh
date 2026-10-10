#!/usr/bin/env bash
# Builds tools/tlbpin → build/tlbpin/msls31.dll (x86_64): msls31 shim → msls31_ms.dll + pins the TOM typelib.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/tlbpin/msls31.dll"
mkdir -p "$ROOT/build/tlbpin"
"$CC" -shared -O2 -Wall -o "$ROOT/build/tlbpin/msls31.dll" "$ROOT/tools/tlbpin/tlbpin.c" "$ROOT/tools/tlbpin/msls31.def" -loleaut32
echo "built: $ROOT/build/tlbpin/msls31.dll"
