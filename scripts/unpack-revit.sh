#!/usr/bin/env bash
# Unpacks the Revit <year> installer from installers/revit<year>/ into installers/extracted/revit<year>/, then lays the
# updates in installers/revit<year>/update/ (scripts/get-revit.sh) over it, oldest first, each once.
# Usage: ./scripts/unpack-revit.sh <year>     Log: logs/revit<year>/<time>-unpack/unpack.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
[ $# -eq 1 ] || usage_die "Usage: scripts/unpack-revit.sh <year>"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
command -v 7zz >/dev/null || die "7zz required: brew install sevenzip"
lock_take "unpack-revit.sh $YEAR"
SRC="$(revit_installers "$YEAR")"; DST="$(revit_extracted "$YEAR")"
LOGD="$(run_dir_new "revit$YEAR" unpack)" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
exec > >(tee "$LOGD/unpack.log" 7>&- 9>&-) 2>&1
if [ -d "$DST" ]; then
  echo "== already unpacked: installers/extracted/revit$YEAR"
else
  main="$(revit_main_installer "$YEAR")"
  [ -n "$main" ] || die "!! no Revit $YEAR installer in installers/revit$YEAR/"
  echo "== unpacking $(basename "$main") into installers/extracted/revit$YEAR"
  # into a temporary folder first: a failed unpack must not look like a finished one next time
  rm -rf "$DST.partial"; mkdir -p "$DST.partial" || die "!! cannot create $DST.partial"
  case "$main" in   # Autodesk multi-part downloads (2020, the 2024 base) are not 7z: tools/adsk_sfx.py reads them
    *.sfx.exe) python3 -I "$ROOT/tools/adsk_sfx.py" "$main" "$DST.partial" ;;
    *)         7zz x -y -o"$DST.partial" "$main" >/dev/null ;;
  esac || { rm -rf "$DST.partial"; die "!! unpacking failed (an incomplete download or a full disk?); removed the partial files"; }
  [ -n "$(find "$DST.partial" -maxdepth 4 \( -iname setup.xml -o -iname Setup.ini \) | head -1)" ] \
    || { rm -rf "$DST.partial"; die "!! the unpacked files have no Setup.ini or setup.xml: not a Revit installer?"; }
  mv "$DST.partial" "$DST" || die "!! cannot rename $DST.partial"
fi
# an update is an ODIS bundle with the same package folders as the base (x64/<pkg>/, 3rdParty/), full packages, not
# patches: laid over the base so the steps take the updated packages. Its own top-level setup.xml is not copied
root="$(revit_dist "$YEAR")"; ups=()
while IFS= read -r u; do ups+=("$u"); done < <(ls "$SRC"/update/*.exe 2>/dev/null | sort -V)   # not $(ls): spaces
for u in ${ups[@]+"${ups[@]}"}; do
  grep -qxF "$(basename "$u")" "$root/applied-updates.txt" 2>/dev/null && continue
  echo "== applying update $(basename "$u")"
  7zz x -y -o"$root" "$u" x64 3rdParty >/dev/null || die "!! update failed: $u"
  basename "$u" >> "$root/applied-updates.txt"
done
echo "== ready: installers/extracted/revit$YEAR"
