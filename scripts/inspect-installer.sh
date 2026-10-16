#!/usr/bin/env bash
# Reports on a Revit <year> installer before the version is set up: its type, MSIs, prerequisites, Setup.ini sequences.
# Usage: ./scripts/inspect-installer.sh <year>   (also for a year without a profile yet)
# Reads installers/revit<year>/ and, once unpacked (scripts/unpack-revit.sh), installers/extracted/revit<year>/.
# Changes nothing. Report: logs/revit<year>/<time>-inspect/report.txt — summarize it in versions/<year>.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
YEAR="${1:-}"; [[ "$YEAR" =~ ^[0-9]{4}$ ]] || usage_die "Usage: scripts/inspect-installer.sh <year>"
command -v 7zz >/dev/null || die "7zz required: brew install sevenzip"
SRC="$(revit_input "$YEAR")"; DST="$(revit_extracted "$YEAR")"
OUTD="$(run_dir_new "revit$YEAR" inspect)" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
OUT="$OUTD/report.txt"
exec > >(tee "$OUT" 7>&- 9>&-) 2>&1

if load_profile "$YEAR"; then echo "== Revit $YEAR: profile scripts/profiles/$YEAR.sh, .NET $DOTNET"
else echo "== Revit $YEAR: no profile yet"; fi
echo "== files in installers/revit$YEAR:"
find -H "$SRC" -maxdepth 2 -type f ! -name .gitkeep -exec ls -lh {} \; 2>/dev/null | awk '{print "   "$5"  "$NF}'
main="$(revit_main_installer "$YEAR")"
[ -n "$main" ] || { echo "!! no installer in $SRC"; exit 1; }
echo "== main file: $main"
echo "   sha256: $(shasum -a 256 "$main" | cut -d' ' -f1)  (add to installers/CHECKSUMS.txt)"
echo "== type per 7zz:"; 7zz l "$main" 2>/dev/null | grep -E '^(Type|Physical Size|Method)' | sed 's/^/   /'
[ -d "$DST" ] || { echo "== contents (not unpacked, first 60 lines):"; 7zz l "$main" | sed -n '/^-----/,$p' | head -60; exit 0; }

echo "== installer markers:"
for f in Setup.ini setup.xml Setup.exe Installer.exe manifest.xml bundle.xml; do
  find "$DST" -maxdepth 4 -iname "$f" | head -3 | sed "s|$DST/|   $f: |"
done
find "$DST" -maxdepth 6 -ipath '*odis*' | head -3 | sed "s|$DST/|   ODIS: |"
echo "== MSI (size, path):"
find "$DST" -iname '*.msi' -exec ls -lh {} \; | awk '{print "   "$5"  "$NF}' | sed "s|$DST/||" | sort -k2 | head -80
echo "== prerequisites (.NET / VC++ / WebView2 / DirectX):"
find "$DST" \( -iname '*ndp*' -o -iname '*dotnet*' -o -iname '*windowsdesktop-runtime*' -o -iname '*vc_redist*' -o -iname '*vcredist*' \
  -o -iname '*WebView2*' -o -iname '*dxsetup*' \) -maxdepth 8 2>/dev/null | sed "s|$DST/|   |" | head -40
ini=$(find "$DST" -maxdepth 4 -iname Setup.ini | head -1)
if [ -n "$ini" ]; then
  echo "== Setup.ini: sequences"
  iconv -f utf-16 -t utf-8 "$ini" 2>/dev/null | tr -d '\r' | grep -E '^(PREREQUISITE|INSTALL_SEQUENCE|POSTREQUISITE)=' | sed 's/^/   /' \
    || tr -d '\r' < "$ini" | grep -E '^(PREREQUISITE|INSTALL_SEQUENCE|POSTREQUISITE)=' | sed 's/^/   /'
fi
echo "== report: $(tilde "$OUT")"
