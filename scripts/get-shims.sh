#!/usr/bin/env bash
# Puts our shims into build/: the pinned GitHub release if it fits the sources, else the compiler to build them.
# Usage: ./scripts/get-shims.sh          (SHIMS_FROM_SOURCE=1 forces a source build)
# The release is built by GitHub Actions from tag v$SHIMS_VERSION; its SHA-256 is pinned in scripts/lib/shims.sh,
# so a changed or corrupt download is rejected. A package counts only when it holds a file for every shim of SHIMS
# (one of an older layout does not). Saves the ~760 MB compiler download for most users.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"; lock_take "get-shims.sh"
DL=""; trap '[ -z "$DL" ] || rm -rf "$DL"' EXIT   # this script's download folder, nothing else
from_source() { # without the marker build-shims.sh takes no release file, and none may stay to be copied later
  echo "$1 — building from source"
  rm -f "$ROOT/build/.prebuilt" "$ROOT/build/LICENSE" "$ROOT"/build/*/*.dll "$ROOT"/build/*/*.exe
  [ -z "$DL" ] || rm -rf "$DL"   # exec skips the EXIT trap
  exec "$ROOT/scripts/get-toolchain.sh"
}
release_complete() { # $1 = folder: a .dll or .exe in <folder>/<shim>/ for every shim of SHIMS
  local s f found
  for s in "${SHIMS[@]}"; do
    found=""; for f in "$1/$s"/*.dll "$1/$s"/*.exe; do [ -f "$f" ] && found=1; done
    [ -n "$found" ] || return 1
  done
}

[ "${SHIMS_FROM_SOURCE:-0}" = 1 ] && from_source "SHIMS_FROM_SOURCE=1"
# a clone whose shim sources differ from the release tag (local edits, newer main) must not get the old DLLs
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SHIMS_VERSION" >/dev/null 2>&1; then
  git -C "$ROOT" diff --quiet "v$SHIMS_VERSION" -- "${SHIMS_SOURCES[@]}" || from_source "shim sources changed since v$SHIMS_VERSION"
fi
[ "$(cat "$ROOT/build/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] && release_complete "$ROOT/build" &&
  { echo "prebuilt shims v$SHIMS_VERSION already in build/"; exit 0; }

ZIP="revit-macos-shims-$SHIMS_VERSION.zip"
URL="https://github.com/$SHIMS_REPO/releases/download/v$SHIMS_VERSION/$ZIP"
DL="$(mktemp -d)"
echo ">> downloading $URL"
curl -fsSL --retry 3 -o "$DL/$ZIP" "$URL" || from_source "download failed"
echo "$SHIMS_SHA256  $DL/$ZIP" | shasum -a 256 -c --quiet - || from_source "checksum mismatch"
unzip -q -o "$DL/$ZIP" -d "$DL/x"   # the archive holds build/<shim>/<file>
release_complete "$DL/x/build" || from_source "release v$SHIMS_VERSION does not hold every shim of these sources"
# in place of every release or built file: no file of another build may sit next to the release's
rm -f "$ROOT/build/.prebuilt" "$ROOT/build/LICENSE" "$ROOT"/build/*/*.dll "$ROOT"/build/*/*.exe
mkdir -p "$ROOT/build" && cp -R "$DL/x/build/." "$ROOT/build/"
echo "$SHIMS_VERSION" > "$ROOT/build/.prebuilt"
echo ">> prebuilt shims v$SHIMS_VERSION in build/:"; unzip -Z1 "$DL/$ZIP" | sed 's/^/   /'
