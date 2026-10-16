#!/usr/bin/env bash
# Unpacks the Revit <year> installer (the source tools/installer_source.py resolves) into installers/extracted/revit<year>/,
# lays its updates over it, oldest first, each once, and records the source in .source. A new unpack goes to
# <folder>.partial and replaces the old one only when complete.
# Usage: ./scripts/unpack-revit.sh <year>     Log: logs/revit<year>/<time>-unpack/unpack.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
[ $# -eq 1 ] || usage_die "Usage: scripts/unpack-revit.sh <year>"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
command -v 7zz >/dev/null || die "7zz required: brew install sevenzip"
lock_take "unpack-revit.sh $YEAR"
SRC="$(revit_input "$YEAR")"; DST="$(revit_extracted "$YEAR")"
LOGD="$(run_dir_new "revit$YEAR" unpack)" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
exec > >(tee "$LOGD/unpack.log" 7>&- 9>&-) 2>&1   # stdout/stderr into the log too; fd 7 and 9 stay as they are
SL="${REVIT_SOURCE_LIST:-}"
if [ -z "$SL" ]; then
  SL="$LOGD/source.list"
  python3 -I "$ROOT/tools/installer_source.py" resolve "$YEAR" "$SRC" "$(revit_downloads "$YEAR")" "$ROOT/installers/CHECKSUMS.txt" "$SL" >/dev/null 2>&1
fi
extracted_recover "$DST"   # install.sh did it before deciding; by hand, here
if [ -d "$DST" ] && [ "${REVIT_REUSE_EXTRACTED:-0}" = 1 ] && [ "${REVIT_UNPACK_AGAIN:-}" != 1 ]; then
  # used exactly as it is: no installer file is read, so a broken or conflicting one does not matter
  echo "== already unpacked: installers/extracted/revit$YEAR"; echo "== ready: installers/extracted/revit$YEAR"; exit 0
fi
# every path below works on checked files: sums against the known ones, one copy per update name (two different
# copies stop here), the warnings for unknown sums
python3 -I "$ROOT/tools/installer_source.py" finalize "$SL" "$DATA/installers/.hashes" >/dev/null || die "!! the installer files do not check out"
for n in $(/usr/bin/perl -MJSON::PP -0 -ne 'print "$_\n" for @{decode_json($_)->{unknown}}' "$SL"); do   # for the app only
  emit message level "$(json_str warn)" text "$(json_str "$n: no known checksum (a build this project has not seen); used as it is")"
done
ups=(); while IFS= read -r u; do ups+=("$u"); done < <(/usr/bin/perl -MJSON::PP -0 -ne 'my $s = eval { decode_json($_) } or exit 0;
  print "$_->{path}\n" for grep { $_->{role} eq "update" && -f $_->{path} } @{$s->{files}}' "$SL" 2>/dev/null)
apply_updates() { # $1 = installer root: the list's updates, in order, each once. An update is an ODIS bundle with the
  # base's package folders (x64/<pkg>/, 3rdParty/), full packages, not patches; its own setup.xml is not copied
  local u
  for u in ${ups[@]+"${ups[@]}"}; do
    grep -qxF "$(basename "$u")" "$1/applied-updates.txt" 2>/dev/null && continue
    echo "== applying update $(basename "$u")"
    7zz x -y -o"$1" "$u" x64 3rdParty >/dev/null 7>&- || return 1
    basename "$u" >> "$1/applied-updates.txt"
  done
}
if [ -d "$DST" ] && [ "${REVIT_UNPACK_AGAIN:-}" != 1 ]; then
  echo "== already unpacked: installers/extracted/revit$YEAR"
  # made before .source existed: as before, the (now checked) updates go on top; a recorded one stays as recorded
  [ -f "$DST/.source" ] || apply_updates "$(revit_dist "$YEAR")" || die "!! update failed"
  echo "== ready: installers/extracted/revit$YEAR"; exit 0
fi
complete="$(/usr/bin/perl -MJSON::PP -0 -ne 'print decode_json($_)->{source_id} ? 1 : 0' "$SL")"
[ "$complete" = 1 ] || die "!! the Revit $YEAR installer is not complete in installers/revit$YEAR/; nothing changed"   # also: only updates left
if [ -d "$DST" ]; then   # unpack again: never while another bottle of this year still installs from it
  B="$(bottle_path "${REVIT_FOR_BOTTLE:-none}")"
  if o="$(other_bottle_of_year)"; then result_set result in_use; die "!! bottle $o still uses installers/extracted/revit$YEAR; nothing changed"; fi
fi
main="$(revit_main_installer "$YEAR" "$SL")"
[ -n "$main" ] || die "!! no Revit $YEAR installer in installers/revit$YEAR/"
echo "== unpacking $(basename "$main") into installers/extracted/revit$YEAR"
# into a temporary folder first: a failed unpack must not look like a finished one, and must not cost the old one
rm -rf "$DST.partial"; mkdir -p "$DST.partial" || die "!! cannot create $DST.partial"
case "$main" in   # Autodesk multi-part downloads (2020, the 2024 base) are not 7z: tools/adsk_sfx.py reads them
  *.sfx.exe) python3 -I "$ROOT/tools/adsk_sfx.py" "$main" "$DST.partial" ;;
  *)         7zz x -y -o"$DST.partial" "$main" >/dev/null 7>&- ;;
esac || { rm -rf "$DST.partial"; die "!! unpacking failed (an incomplete download or a full disk?); removed the partial files"; }
[ -n "$(find "$DST.partial" -maxdepth 4 \( -iname setup.xml -o -iname Setup.ini \) | head -1)" ] \
  || { rm -rf "$DST.partial"; die "!! the unpacked files have no Setup.ini or setup.xml: not a Revit installer?"; }
apply_updates "$(revit_dist_of "$DST.partial")" || { rm -rf "$DST.partial"; die "!! an update failed; the old unpacked files are kept"; }
cp "$SL" "$DST.partial/.source" || die "!! cannot write $DST.partial/.source"
bak="$DST.old.$$"   # a name of this run only
if [ -d "$DST" ]; then mv "$DST" "$bak" || die "!! cannot move the old unpacked files"; fi
if ! mv "$DST.partial" "$DST"; then
  [ ! -d "$bak" ] || mv "$bak" "$DST" || die "!! cannot rename $DST.partial, and the old unpacked files are in $bak"
  die "!! cannot rename $DST.partial; the old unpacked files are kept"
fi
rm -rf "$bak"
echo "== ready: installers/extracted/revit$YEAR"
