#!/usr/bin/env bash
# Builds tools/pdf-printer/add_printer.c → build/pdf-printer/add_printer.exe (x86_64).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "build-add-printer.sh"
CC="$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
. "$ROOT/scripts/lib/shims.sh"; cc_or_prebuilt "$ROOT/build/pdf-printer/add_printer.exe"
OUT="$ROOT/build/pdf-printer"; mkdir -p "$OUT"
"$CC" -O2 -Wall -municode -o "$OUT/add_printer.exe" "$ROOT/tools/pdf-printer/add_printer.c" -lwinspool
echo "built: $OUT/add_printer.exe"
