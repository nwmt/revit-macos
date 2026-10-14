#!/usr/bin/env bash
# Builds every shim (scripts/build-shims.sh, the list in scripts/lib/shims.sh) and packs them for a GitHub release,
# so users can skip the toolchain.
# Usage: ./scripts/build-release.sh <version>   → dist/revit-macos-shims-<version>.zip + .sha256
set -euo pipefail
VER="${1:?specify a version, e.g. 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"; lock_take "build-release.sh"
"$ROOT/scripts/get-toolchain.sh"
rm -rf "$ROOT/build"   # clean build: no stale probes or old DLLs in the package
"$ROOT/scripts/build-shims.sh"
OUT="$ROOT/dist/revit-macos-shims-$VER.zip"; mkdir -p "$ROOT/dist"; rm -f "$OUT"
# the license goes with the files; build/, not the root: get-shims.sh unpacks into the repo root
cp "$ROOT/LICENSE" "$ROOT/build/LICENSE"
(cd "$ROOT" && { echo build/LICENSE
  for s in "${SHIMS[@]}"; do find "build/$s" -maxdepth 1 -type f \( -name '*.dll' -o -name '*.exe' \); done | sort; } | zip -q -X "$OUT" -@)
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
unzip -l "$OUT"; cat "$OUT.sha256"
