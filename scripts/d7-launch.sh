#!/usr/bin/env bash
# D7: launches Revit in a bottle with logs. Doesn't wait: Revit is a GUI app. Year from REVIT_YEAR (default 2020).
# Usage: ./scripts/d7-launch.sh <bottle> [CX_GRAPHICS_BACKEND: default|d3dmetal|dxmt|wined3d|dxvk] [file.rvt/.rfa, Windows path]
# Revit journals: drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit <year>/Journals
set -uo pipefail
NAME="${1:?specify a bottle}"; BE="${2:-default}"; FILE="${3:-}"; YEAR="${REVIT_YEAR:-2020}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
RUN="$ROOT/logs/d7-$NAME-$BE-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$RUN"
cd "$B/drive_c"
env_be=(); [ "$BE" != default ] && env_be=(CX_GRAPHICS_BACKEND="$BE")
env ${env_be[@]+"${env_be[@]}"} CX_LOG="$RUN/wine.cxlog" CX_DEBUGMSG="${CX_DEBUGMSG:-err,+seh}" \
  "$CX/bin/wine" --bottle "$NAME" "C:\\Program Files\\Autodesk\\Revit $YEAR\\Revit.exe" ${FILE:+"$FILE"} >"$RUN/stdout.log" 2>&1 &
echo "$!" > "$RUN/pid"
echo "started pid=$! backend=$BE logs=$RUN"
