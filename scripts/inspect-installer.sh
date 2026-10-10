#!/usr/bin/env bash
# Inspects the Revit <year> installer before installing: installer type, MSIs, prerequisites, required .NET.
# Usage: ./scripts/inspect-installer.sh <year> [--extract]
#   looks in installers/revit<year>/ (.exe sfx / .iso / .zip / an already extracted folder);
#   --extract — extract (7zz) to installers/extracted/revit<year>/ (10–40 GB, gitignored).
# Report: logs/inspect-revit<year>-<ts>.txt — summarize it in versions/<year>.md.
set -uo pipefail
YEAR="${1:?specify a year, e.g. 2026}"; EXTRACT="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
SRC="$(revit_installers "$YEAR")"; DST="$(revit_extracted "$YEAR")"
OUT="$ROOT/logs/inspect-revit$YEAR-$(date +%Y%m%d-%H%M%S).txt"; mkdir -p "$ROOT/logs"
command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip" >&2; exit 1; }
exec > >(tee "$OUT") 2>&1

echo "== Revit $YEAR: expected .NET $(revit_dotnet "$YEAR"); expectation: $(revit_expect "$YEAR")"
echo "== files in installers/revit$YEAR:"
find "$SRC" -maxdepth 2 -type f ! -name .gitkeep -exec ls -lh {} \; 2>/dev/null | awk '{print "   "$5"  "$NF}'
# largest archive: in "db" downloads (2023+) *_001_002.exe is a 16 MB bootstrapper, the payload is *_002_002.7z
main=$(find "$SRC" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.iso' -o -iname '*.zip' -o -iname '*.7z' \) \
  -exec stat -f '%z %N' {} + | sort -n | tail -1 | cut -d' ' -f2-)
# multi-part downloads (2020: *_001_007.sfx.exe … *_007_007.sfx.exe, equal sizes) start from part 001
first=$(find "$SRC" -maxdepth 2 -type f -iname '*_001_0*.sfx.exe' | sort | head -1)
[ -n "$first" ] && main="$first"
[ -n "$main" ] || { echo "!! no installer in $SRC"; exit 1; }
echo "== main file: $main"
echo "   sha256: $(shasum -a 256 "$main" | cut -d' ' -f1)  (add to installers/CHECKSUMS.txt)"
echo "== type per 7zz:"; 7zz l "$main" 2>/dev/null | grep -E '^(Type|Physical Size|Method)' | sed 's/^/   /'

if [ "$EXTRACT" = --extract ] && [ ! -d "$DST" ]; then
  # into a temp folder first: a failed extraction must not look like a finished one on the next run
  echo "== extracting to $DST"; rm -rf "$DST.partial"; mkdir -p "$DST.partial"
  # Autodesk multi-part downloads (2020) are not 7z: tools/adsk_sfx.py reads them directly
  case "$main" in *.sfx.exe) unpack() { python3 -I "$ROOT/tools/adsk_sfx.py" "$main" "$DST.partial"; } ;;
                  *)         unpack() { 7zz x -y -o"$DST.partial" "$main" >/dev/null; } ;; esac
  if ! unpack; then
    echo "!! extraction failed (incomplete download or full disk?); removed $DST.partial"; rm -rf "$DST.partial"; exit 1
  fi
  if [ -z "$(find "$DST.partial" -maxdepth 4 \( -iname setup.xml -o -iname Setup.ini \) | head -1)" ]; then
    echo "!! extracted files have no Setup.ini or setup.xml — not a Revit installer?"; rm -rf "$DST.partial"; exit 1
  fi
  mv "$DST.partial" "$DST"
fi
[ -d "$DST" ] || { echo "== contents (not extracted, first 60 lines):"; 7zz l "$main" | sed -n '/^-----/,$p' | head -60; exit 0; }

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
echo "== report: $OUT"
