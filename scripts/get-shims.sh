#!/usr/bin/env bash
# Puts our shim DLLs into build/: the pinned GitHub release if it matches the sources, else the compiler to build them.
# Usage: ./scripts/get-shims.sh          (SHIMS_FROM_SOURCE=1 forces a source build)
# The release is built by GitHub Actions from tag v$SHIMS_VERSION; its SHA-256 is pinned in scripts/lib/shims.sh,
# so a changed or corrupt download is rejected. Saves the ~760 MB compiler download for most users.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/shims.sh"
from_source() { echo "$1 — building from source"; rm -f "$ROOT/build/.prebuilt"; exec "$ROOT/scripts/get-toolchain.sh"; }

[ "${SHIMS_FROM_SOURCE:-0}" = 1 ] && from_source "SHIMS_FROM_SOURCE=1"
# a clone whose shim sources differ from the release tag (local edits, newer main) must not get the old DLLs
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SHIMS_VERSION" >/dev/null 2>&1; then
  git -C "$ROOT" diff --quiet "v$SHIMS_VERSION" -- "${SHIMS_SOURCES[@]}" || from_source "shim sources changed since v$SHIMS_VERSION"
fi
[ "$(cat "$ROOT/build/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] && { echo "prebuilt shims v$SHIMS_VERSION already in build/"; exit 0; }

ZIP="revit-macos-shims-$SHIMS_VERSION.zip"
URL="https://github.com/$SHIMS_REPO/releases/download/v$SHIMS_VERSION/$ZIP"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo ">> downloading $URL"
curl -fsSL --retry 3 -o "$TMP/$ZIP" "$URL" || from_source "download failed"
echo "$SHIMS_SHA256  $TMP/$ZIP" | shasum -a 256 -c --quiet - || from_source "checksum mismatch"
unzip -q -o "$TMP/$ZIP" -d "$ROOT"   # the archive holds build/<shim>/<file>
echo "$SHIMS_VERSION" > "$ROOT/build/.prebuilt"
echo ">> prebuilt shims v$SHIMS_VERSION in build/:"; unzip -Z1 "$TMP/$ZIP" | sed 's/^/   /'
