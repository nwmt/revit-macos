#!/usr/bin/env bash
# Windows cross-compiler without brew/sudo: llvm-mingw (mstorsjo) → toolchain/llvm-mingw (gitignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "get-toolchain.sh"
VER=20261006
SHA=a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6
[ -x "$ROOT/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang" ] && { echo "already installed"; exit 0; }
mkdir -p "$ROOT/toolchain" && cd "$ROOT/toolchain"
curl -fL -o llvm-mingw.tar.xz "https://github.com/mstorsjo/llvm-mingw/releases/download/$VER/llvm-mingw-$VER-ucrt-macos-universal.tar.xz"
echo "$SHA  llvm-mingw.tar.xz" | shasum -a 256 -c
tar xf llvm-mingw.tar.xz && rm llvm-mingw.tar.xz
mv "llvm-mingw-$VER-ucrt-macos-universal" llvm-mingw
xattr -dr com.apple.quarantine llvm-mingw 2>/dev/null || true
