#!/usr/bin/env bash
# Builds the app and its DMG into dist/app/: fetches the pinned tools (app/fetch-tools.sh), builds the Swift app,
# assembles the bundle (app/make-bundle.sh), signs it (app/sign.sh), runs the engine from it once (it must work and
# write nothing into the bundle), then makes the DMG (app/make-dmg.sh). The workflow .github/workflows/app.yml runs it.
# Usage: app/build.sh <version X.Y.Z>
#   → dist/app/<App>.app, <App-with-dashes>-<version>.dmg (+ .sha256), inventory.txt, sources/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/app/app.conf"; . "$ROOT/app/tools.sh"
VER="${1:-}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: app/build.sh <version X.Y.Z>" >&2; exit 2; }
die() { echo "!! $*" >&2; exit 1; }
D="$ROOT/dist/app"; APP="$D/$APP_NAME.app"; E="$APP/Contents/Resources/engine"
rm -rf "$D"; mkdir -p "$D"

"$ROOT/app/fetch-tools.sh" "$D/tools"
mv "$D/tools/sources" "$D/sources"   # published next to the DMG (GPL/LGPL source)
for s in "$(basename "$SEVENZIP_SRC_URL")" "$(basename "$CABEXTRACT_URL")"; do [ -f "$D/sources/$s" ] || die "no $s in $D/sources"; done

echo ">> building the app" >&2
swift build --package-path "$ROOT/app" -c release --arch arm64
BIN="$(swift build --package-path "$ROOT/app" -c release --arch arm64 --show-bin-path)/AppMain"
"$ROOT/app/make-bundle.sh" "$APP" "$BIN" "$D/tools" "$VER"
"$ROOT/app/sign.sh" "$APP" "$APP_MIN_MACOS" "$D/inventory.txt"

# smoke test: the engine from the signed bundle, as the app starts it (a minimal PATH, a fresh HOME: no real data)
echo ">> smoke test" >&2
H="$(mktemp -d)"; trap 'rm -rf "$H"' EXIT; touch "$H/stamp"
run() { env -i HOME="$H" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" /bin/bash "$@"; }
run "$E/scripts/check-bundle.sh" || die "check-bundle.sh failed in the built app"
st="$(run "$E/revit" status --json)" || die "revit status --json failed in the built app"
[ "$(/usr/bin/perl -MJSON::PP -e 'print decode_json($ARGV[0])->{app}{version} // ""' "$st")" = "$VER" ] \
  || die "status --json does not report the app version $VER: $st"
mkdir "$H/ci"; printf '<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>' > "$H/collection.xml"
(cd "$H" && zip -q "ci/Create_Installer_RVT_2025_5_English_WIN64.exe" collection.xml)   # a fake Create Installer
fi_="$(run "$E/revit" find-installer "$H/ci" --json)" || die "revit find-installer failed in the built app"
[ "$(/usr/bin/perl -MJSON::PP -e 'print decode_json($ARGV[0])->{kind} // ""' "$fi_")" = create-installer ] \
  || die "find-installer did not read the fake Create Installer (Python and 7zz from the app): $fi_"
codesign --verify --strict --deep "$APP" || die "the smoke test broke the app's signature"
changed="$(find "$APP" -newer "$H/stamp")"; [ -z "$changed" ] || die "the smoke test wrote into the app: $changed"
echo ">> smoke test passed: the tools, the shims, status, find-installer; nothing written into the app" >&2

"$ROOT/app/make-dmg.sh" "$APP" "$D/${APP_NAME// /-}-$VER.dmg"
echo ">> $D: $(basename "$APP"), ${APP_NAME// /-}-$VER.dmg, inventory.txt ($(wc -l < "$D/inventory.txt" | tr -d ' ') Mach-O images), sources/"
