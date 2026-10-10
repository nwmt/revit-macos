#!/usr/bin/env bash
# Creates ~/Applications/Revit <year> (<bottle>).app — launches Revit from the bottle without debug logs (for daily use, not D7).
# Usage: ./scripts/make-launcher.sh <bottle> [year]
#   year: argument, else $REVIT_YEAR, else the 4 digits in the bottle name (rvt2026-a → 2026), else 2020.
# Why: CrossOver 26 cxmenu doesn't create a shortcut for "Revit <year>.lnk" (it does for Viewer and the rest).
set -euo pipefail
NAME="${1:?specify a bottle}"
YEAR="${2:-${REVIT_YEAR:-}}"
if [ -z "$YEAR" ]; then
  if [[ "$NAME" =~ ([0-9]{4}) ]]; then YEAR="${BASH_REMATCH[1]}"; else YEAR=2020; fi
fi
APP="$HOME/Applications/Revit $YEAR ($NAME).app"
CXW="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
rm -rf "$APP"
osacompile -o "$APP" -e "do shell script \"cd ~ && '$CXW' --bottle '$NAME' 'C:\\\\Program Files\\\\Autodesk\\\\Revit $YEAR\\\\Revit.exe' >/dev/null 2>&1 &\""
ICON="$(find "$HOME/Applications/CrossOver" -path "*Revit Viewer $YEAR.app/Contents/Resources/*.icns" 2>/dev/null | head -1 || true)"
[ -n "$ICON" ] || ICON="$(find "$HOME/Applications/CrossOver" -path "*Revit*$YEAR*.app/Contents/Resources/*.icns" 2>/dev/null | head -1 || true)"
[ -n "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/applet.icns"
touch "$APP"
echo "done: $APP"
