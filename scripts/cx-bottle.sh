#!/usr/bin/env bash
# Creates a clean CrossOver bottle for an experiment (rule: prefixes are disposable).
# Usage: ./scripts/cx-bottle.sh <name> [template=win10_64]
#   ./scripts/cx-bottle.sh revit2020-a
# Recreate from scratch: CX_RECREATE=1 ./scripts/cx-bottle.sh revit2020-a
set -euo pipefail

NAME="${1:?specify a bottle name}"
TEMPLATE="${2:-win10_64}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
BOTTLES="$HOME/Library/Application Support/CrossOver/Bottles"
LOG="$(cd "$(dirname "$0")/.." && pwd)/logs/bottle-$NAME-$(date +%Y%m%d-%H%M%S).log"

[ -x "$CX/bin/cxbottle" ] || { echo "CrossOver not found in /Applications" >&2; exit 1; }

if [ -d "$BOTTLES/$NAME" ]; then
  if [ "${CX_RECREATE:-0}" = 1 ]; then
    echo ">> deleting old bottle $NAME"
    "$CX/bin/cxbottle" --bottle "$NAME" --delete --force
  else
    echo "bottle $NAME already exists; set CX_RECREATE=1 to recreate" >&2; exit 1
  fi
fi

echo ">> creating $NAME ($TEMPLATE), log: $LOG"
"$CX/bin/cxbottle" --bottle "$NAME" --create --template "$TEMPLATE" \
  --description "${CX_DESC:-Revit experiment}" >>"$LOG" 2>&1

echo ">> wineboot"
"$CX/bin/wine" --bottle "$NAME" --wait-children wineboot -u >>"$LOG" 2>&1 || true

echo ">> check"
"$CX/bin/wine" --bottle "$NAME" --wait-children cmd /c ver 2>>"$LOG" | tr -d '\r'
"$CX/bin/wine" --bottle "$NAME" --wait-children reg query \
  'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v CurrentBuild 2>>"$LOG" | tr -d '\r' | grep -i build || true
echo ">> done: $BOTTLES/$NAME"
