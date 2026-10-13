#!/usr/bin/env bash
# Builds every shim DLL and packs them for a GitHub release, so users can skip the toolchain.
# Usage: ./scripts/build-release.sh <version>   → dist/revit-macos-shims-<version>.zip + .sha256
set -euo pipefail
VER="${1:?specify a version, e.g. 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "build-release.sh"
"$ROOT/scripts/get-toolchain.sh"
rm -rf "$ROOT/build"   # clean build: no stale probes or old DLLs in the package
for s in "$ROOT"/scripts/build-{add-printer,d3dwp,ncrypt-shim,rvtfix,svcshim,tlbpin,vkshim,wbem-shim,wv2fix}.sh; do
  echo ">> $(basename "$s")"; "$s" >/dev/null
done
OUT="$ROOT/dist/revit-macos-shims-$VER.zip"; mkdir -p "$ROOT/dist"; rm -f "$OUT"
# the license goes with the files; build/, not the root: get-shims.sh unpacks into the repo root
cp "$ROOT/LICENSE" "$ROOT/build/LICENSE"
(cd "$ROOT" && { echo build/LICENSE; find build/{d3dwp,ncrypt-shim,pdf-printer,rvtfix,svcshim,tlbpin,vkshim,wbem-shim,wv2fix} -type f \( -name '*.dll' -o -name '*.exe' \) | sort; } | zip -q -X "$OUT" -@)
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
unzip -l "$OUT"; cat "$OUT.sha256"
