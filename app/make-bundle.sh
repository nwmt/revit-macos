#!/usr/bin/env bash
# Assembles <App>.app (name and bundle ID from app/app.conf):
#   Contents/MacOS/<App>                the menu bar app
#   Contents/Resources/engine/          revit, install.sh, scripts/, tools/, installers/CHECKSUMS.txt, LICENSE, .app-bundle
#   Contents/Resources/engine/build/    the shims release (+ .prebuilt)
#   Contents/Resources/bin/, python/    7zz, cabextract, winetricks; Python
#   Contents/Resources/Licenses/        one folder per component + README.txt
# The engine reads .app-bundle (scripts/lib/common.sh): data in ~/Library/Application Support/<App>, these tools first.
# Usage: app/make-bundle.sh <out.app> <app binary> <tools folder from app/fetch-tools.sh> <version X.Y.Z>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
refuse() { echo "$*" >&2; exit 2; }
[ $# = 4 ] || refuse "Usage: app/make-bundle.sh <out.app> <app binary> <tools folder> <version X.Y.Z>"
OUT="$1"; BIN="$2"; TOOLS="$3"; VER="$4"
. "$ROOT/app/app.conf"; . "$ROOT/app/tools.sh"; . "$ROOT/scripts/lib/shims.sh"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "The version must look like X.Y.Z: $VER"
[[ "$APP_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ ]*$ ]] || refuse "APP_NAME in app/app.conf may hold letters, digits and spaces only"
[ ! -e "$OUT" ] || refuse "$OUT already exists"
[ -f "$BIN" ] && [ -d "$TOOLS/bin" ] && [ -x "$TOOLS/python/bin/python3" ] || refuse "Missing the app binary or the tools in $TOOLS"
release_complete "$TOOLS/shims" || refuse "The shims in $TOOLS/shims do not hold every shim of SHIMS"
P="$OUT.partial"; trap 'rm -rf "$P"' EXIT; rm -rf "$P"
C="$P/Contents"; RES="$C/Resources"; E="$RES/engine"
mkdir -p "$C/MacOS" "$E/build" "$RES/bin" "$RES/Licenses/revit-macos"

sed -e "s|@APP_NAME@|$APP_NAME|g" -e "s|@APP_BUNDLE_ID@|$APP_BUNDLE_ID|g" -e "s|@APP_VERSION@|$VER|g" \
  -e "s|@APP_MIN_MACOS@|$APP_MIN_MACOS|g" "$ROOT/app/Info.plist.in" > "$C/Info.plist"
plutil -lint -s "$C/Info.plist"
cp "$BIN" "$C/MacOS/$APP_NAME"; chmod 755 "$C/MacOS/$APP_NAME"

# the engine as git sees it (tracked and new files, not ignored ones), without the dev-only scripts: run directly,
# they write into the engine folder and download a compiler; in the app nothing calls them
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- revit install.sh scripts tools installers/CHECKSUMS.txt LICENSE \
  | while IFS= read -r -d '' f; do
      case "$f" in scripts/get-toolchain.sh|scripts/build-shims.sh|scripts/build-release.sh) continue ;; esac
      [ -e "$f" ] && printf '%s\0' "$f"
    done | cpio -p0dm --quiet "$E")
cp -R "$TOOLS/shims/." "$E/build/"; echo "$SHIMS_VERSION" > "$E/build/.prebuilt"
printf 'app_name=%s\napp_version=%s\nsevenzip=%s\ncabextract=%s\nwinetricks=%s\npython=%s\nshims=%s\n' "$APP_NAME" "$VER" \
  "$SEVENZIP_VERSION" "$CABEXTRACT_VERSION" "$WINETRICKS_VERSION" "$PYTHON_VERSION" "$SHIMS_VERSION" > "$E/.app-bundle"

cp -p "$TOOLS"/bin/* "$RES/bin/"; ditto "$TOOLS/python" "$RES/python"
for d in 7-Zip cabextract winetricks Python; do ditto "$TOOLS/licenses/$d" "$RES/Licenses/$d"; done
cp "$ROOT/LICENSE" "$RES/Licenses/revit-macos/LICENSE"
cat > "$RES/Licenses/README.txt" <<EOF
Software included in $APP_NAME $VER, with its license (the texts are in the folders next to this file):

7-Zip $SEVENZIP_VERSION (7zz): GNU LGPL with the unRAR license restriction, and BSD. https://www.7-zip.org
  Source code: $(basename "$SEVENZIP_SRC_URL"), published next to this app's DMG (the GitHub release or build that offers the DMG also offers the source archives).
cabextract $CABEXTRACT_VERSION: GNU GPL 3.0 or later. https://www.cabextract.org.uk
  Source code: $(basename "$CABEXTRACT_URL"), published next to this app's DMG (the GitHub release or build that offers the DMG also offers the source archives).
winetricks $WINETRICKS_VERSION: GNU LGPL 2.1 or later. https://github.com/Winetricks/winetricks (the script is its own source)
Python $PYTHON_VERSION (python-build-standalone): PSF License 2.0, and the licenses of the libraries it includes (Python/). https://github.com/astral-sh/python-build-standalone
revit-macos (the engine and the shims): MIT. https://github.com/$SHIMS_REPO
EOF

# bytecode now, never at run time: python3 -I ignores PYTHONDONTWRITEBYTECODE, and a file written into a user-owned
# app later breaks its signature. unchecked-hash: valid whatever the file times become after copying
"$RES/python/bin/python3" -I -m compileall -q -f -j 0 --invalidation-mode unchecked-hash "$RES/python/lib" >/dev/null

mv "$P" "$OUT"; trap - EXIT
echo ">> $OUT ($APP_NAME $VER)"
