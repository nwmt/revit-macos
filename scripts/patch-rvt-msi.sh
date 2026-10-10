#!/usr/bin/env bash
# Creates x64/RVT/RVT-wine.msi — a copy of RVT.msi where the licensing service check
# (licIsSvcUpgraded → AdskLicensingInstHelper upgrade isUpgraded, always exit 100 under Wine)
# can be disabled with CLM_SKIP_SVCCHECK=1. The original RVT.msi is left untouched.
# Usage: ./scripts/patch-rvt-msi.sh <bottle-with-wine> [year=2020]
# msidb works on a copy in the bottle's C:\rvtmsi: with a Z:\Users\… path it silently failed to export tables from the 2026 RVT.msi.
set -euo pipefail
NAME="${1:?specify a bottle (only its wine is used, for msidb)}"; YEAR="${2:-2020}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
if [ "$YEAR" = 2020 ]; then DIST_UNIX="$(ls -d "$ROOT"/installers/extracted/revit2020/*/ | head -1)"; DIST_UNIX="${DIST_UNIX%/}"
else DIST_UNIX="$(revit_extracted "$YEAR")"; fi
SRC="$DIST_UNIX/x64/RVT/RVT.msi"; DST="$DIST_UNIX/x64/RVT/RVT-wine.msi"
TMP="$B/drive_c/rvtmsi"; rm -rf "$TMP"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
db() { w msidb -d 'C:\rvtmsi\RVT.msi' -f 'C:\rvtmsi' "$@" >/dev/null 2>&1; }

cp "$SRC" "$TMP/RVT.msi"
db -e InstallExecuteSequence
before="$(grep -a '^licIsSvcUpgraded' "$TMP/InstallExecuteSequence.idt")"
perl -i -pe 's/^(licIsSvcUpgraded\.[^\t]+)\tNot Installed\t/$1\tNot Installed AND CLM_SKIP_SVCCHECK<>"1"\t/' "$TMP/InstallExecuteSequence.idt"
after="$(grep -a '^licIsSvcUpgraded' "$TMP/InstallExecuteSequence.idt")"
[ "$before" != "$after" ] || { echo "licIsSvcUpgraded row not found/not changed" >&2; exit 1; }
db -i InstallExecuteSequence.idt
rm -f "$TMP/InstallExecuteSequence.idt"
db -e InstallExecuteSequence
check="$(grep -a '^licIsSvcUpgraded' "$TMP/InstallExecuteSequence.idt")"
[ "$check" = "$after" ] || { echo "msidb -i did not write the change" >&2; exit 1; }
cp "$TMP/RVT.msi" "$DST"
echo "before: $before" | tr '\t' '|'
echo "after:  $check" | tr '\t' '|'
