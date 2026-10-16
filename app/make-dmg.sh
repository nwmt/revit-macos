#!/usr/bin/env bash
# Puts a signed <App>.app on a compressed read-only DMG next to an Applications link (drag to install), and writes
# <out.dmg>.sha256. Usage: app/make-dmg.sh <app> <out.dmg>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/app/app.conf"
[ $# = 2 ] || { echo "Usage: app/make-dmg.sh <app> <out.dmg>" >&2; exit 2; }
APP="${1%/}"; OUT="$2"
[ -d "$APP/Contents" ] || { echo "!! not an app: $APP" >&2; exit 1; }
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"; ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$OUT")"; rm -f "$OUT" "$OUT.sha256"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo ">> $OUT ($(du -h "$OUT" | cut -f1)); $(cut -d' ' -f1 "$OUT.sha256")"
