#!/usr/bin/env bash
# Puts our shims into build/: the pinned GitHub release if it fits the sources, else the compiler to build them.
# Usage: ./scripts/get-shims.sh          (SHIMS_FROM_SOURCE=1 forces a source build)
# The release is built by GitHub Actions from tag v$SHIMS_VERSION; its SHA-256 is pinned in scripts/lib/shims.sh,
# so a changed or corrupt download is rejected. A package counts only when it holds a file for every shim of SHIMS
# (one of an older layout does not). Saves the ~760 MB compiler download for most users.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"; lock_take "get-shims.sh"
DL=""; trap '[ -z "$DL" ] || rm -rf "$DL"' EXIT   # this script's download folder, nothing else
clean_build() { # the release marker, LICENSE and every .dll/.exe in build/<shim>/; a linked folder is not followed
  local d
  rm -f "$ROOT/build/.prebuilt" "$ROOT/build/LICENSE"
  for d in "$ROOT"/build/*/; do [ -L "${d%/}" ] || rm -f "$d"*.dll "$d"*.exe; done
}
from_source() { # without the marker build-shims.sh takes no release file, and none may stay to be copied later
  echo "$1 — building from source"
  clean_build
  [ -z "$DL" ] || rm -rf "$DL"   # exec skips the EXIT trap
  exec "$ROOT/scripts/get-toolchain.sh"
}

if [ "${REVIT_BUNDLED:-0}" = 1 ]; then # the app ships the pinned release: no git, no download, no compiler
  [ "$(cat "$(shim_dir)/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] && release_complete "$(shim_dir)" \
    || { echo "!! the app's shims in $(shim_dir) are not release v$SHIMS_VERSION" >&2; exit 1; }
  echo "prebuilt shims v$SHIMS_VERSION in $(tilde "$(shim_dir)")"; exit 0
fi
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
clean_build
mkdir -p "$ROOT/build" && cp -R "$DL/x/build/." "$ROOT/build/"
echo "$SHIMS_VERSION" > "$ROOT/build/.prebuilt"
echo ">> prebuilt shims v$SHIMS_VERSION in build/:"; unzip -Z1 "$DL/$ZIP" | sed 's/^/   /'
