#!/usr/bin/env bash
# Downloads the full Revit <year> installer that an Autodesk "Create Installer" file points to.
# Usage: ./scripts/get-revit.sh <year>
#   needs installers/revit<year>/Create_Installer_RVT_<year>_*_WIN64.exe from your Autodesk Account.
# Autodesk Account now offers only this 32 MB Windows tool. It is a 7z archive whose collection.xml lists
# the same files the old "Browser download" gave (BrowserImageUrl): *_001_002.exe + *_002_002.7z (2025+)
# or *_dlm_001_005.sfx.exe … (2024). That is the base release (e.g. 2026.0); the update in the tool's name
# (2026.5) is a separate package listed in <bundle>/setup_ext.xml → <dir>/setup.xml (Payload, with SHA-256).
# Files go to the downloads folder (installers/revit<year>/, or installers/revit<year>-dl/ when that is a link to a
# folder of yours, which is never written), the update to its update/; unpack-revit.sh lays it over the unpacked base. Resumes an interrupted download; checks the size, and the SHA-256 when known
# (update: from its manifest; base: installers/CHECKSUMS.txt).
set -uo pipefail
YEAR="${1:?specify a year, e.g. 2027}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; lock_take "get-revit.sh $YEAR"
command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip" >&2; exit 1; }
SL="${REVIT_SOURCE_LIST:-}"; PW=""; TMPSL=""
cleanup() { [ -z "$PW" ] || { kill "$PW" 2>/dev/null; wait "$PW" 2>/dev/null; }; [ -z "$TMPSL" ] || rm -f "$TMPSL"; }
trap cleanup EXIT
if [ -z "$SL" ]; then   # run by hand: resolve here
  TMPSL="$(mktemp "${TMPDIR:-/tmp}/revit-source.XXXXXX")"; SL="$TMPSL"
  python3 -I "$ROOT/tools/installer_source.py" resolve "$YEAR" "$(revit_input "$YEAR")" "$(revit_downloads "$YEAR")" "$ROOT/installers/CHECKSUMS.txt" "$SL" >/dev/null || exit 1
fi
J() { /usr/bin/perl -MJSON::PP -0 -e 'my $s = decode_json(<STDIN>); '"$1" < "$SL"; }
[ "$(J 'print $s->{kind} // ""')" = create-installer ] || { echo "no Create_Installer_RVT_${YEAR}_*.exe in installers/revit$YEAR/" >&2; exit 1; }
ci="$(J 'print $_->{path} for grep { $_->{role} eq "create-installer" } @{$s->{files}}')"
want="$(J 'for (@{$s->{files}}) { next unless $_->{url}; print join("\t", $_->{url}, $_->{path}, $_->{role}, $_->{build} // "?"), "\n" }')"
# only Autodesk's download hosts, only plain file names: the list comes from a file, not from us
while IFS=$'\t' read -r u _ _ _; do
  [[ "$u" =~ ^https://(efulfillment|dds|up1)\.autodesk\.com/[A-Za-z0-9/._-]+$ ]] || { echo "unexpected download URL: $u" >&2; exit 1; }
done <<<"$want"
echo ">> $(basename "$ci"): full installer (the base release), $(grep -c $'\tbase\t' <<<"$want") file(s)"
while IFS=$'\t' read -r _ _ role b; do [ "$role" = update ] && echo "   + update $b"; done <<<"$want"
need=0; plan=()
while IFS=$'\t' read -r u f _ _; do
  size="$(curl -fsSIL --retry 3 "$u" | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')"
  [ -n "$size" ] || { result_set reason download; echo "!! cannot reach $u (offline?)" >&2; exit 1; }
  have="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  if [ "$have" = "$size" ]; then echo "   $(basename "$f"): already here"; continue; fi
  case "$f" in "$(revit_downloads "$YEAR")"/*) ;;   # ours: resumed or replaced below
    *) echo "!! $(basename "$f") in your installer folder is incomplete ($have of $size bytes). Delete it there, or download it again; the folder is never changed here." >&2; exit 1 ;;
  esac
  part="$(stat -f %z "$f.part" 2>/dev/null || echo 0)"
  need=$((need + size - part)); plan+=("$u"$'\t'"$f"$'\t'"$size")
  echo "   $(basename "$f"): $(((size - part) / 1000000)) MB to download"
done <<<"$want"
if [ ${#plan[@]} -gt 0 ]; then
  DLD="$(revit_downloads "$YEAR")"; mkdir -p "$DLD" || { echo "!! cannot write $(tilde "$DLD")" >&2; exit 1; }
  free=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); var r = Ref();
    $.NSURL.fileURLWithPath("/").getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
    ObjC.unwrap(r[0])' 2>/dev/null) || free=""
  [[ "$free" =~ ^[0-9]+$ ]] || free=$(df -k "$DLD" | awk 'NR==2 {print $4 * 1024}')
  [ "$free" -gt $((need + 2000000000)) ] || { result_set reason no_space; echo "!! not enough disk space: need $((need / 1000000000 + 2)) GB, free $((free / 1000000000)) GB" >&2; exit 1; }
  for p in "${plan[@]}"; do
    IFS=$'\t' read -r u f size <<<"$p"; mkdir -p "$(dirname "$f")" || exit 1
    echo ">> $(basename "$f") ($((size / 1000000)) MB)"
    if [ -n "${REVIT_EVENTS_FD:-}" ]; then   # progress for the app: the size of the .part, every 2 s, while this script lives
      ( while kill -0 $$ 2>/dev/null; do emit progress step "$(json_str download)" done "$(stat -f %z "$f.part" 2>/dev/null || echo 0)" total "$size"; sleep 2; done ) 9>&- &
      PW=$!
    fi
    # into .part first: a half-downloaded file must not look finished to install.sh; -C - resumes it
    # curl as run_child: a stop (TERM/INT, Cancel in the app) ends it now; the .part stays for the next run
    for try in 1 2 3 4 5; do
      stop_check
      run_child curl -fL --retry 5 --retry-delay 5 -C - -o "$f.part" "$u" 7>&- && break
      stop_check
      echo "   download interrupted, resuming ($try/5)…"; sleep 5
    done
    [ -z "$PW" ] || { kill "$PW" 2>/dev/null; wait "$PW" 2>/dev/null; PW=""; }
    [ "$(stat -f %z "$f.part" 2>/dev/null || echo 0)" = "$size" ] || { result_set reason download; echo "!! $(basename "$f"): incomplete; run again to resume" >&2; exit 1; }
    mv "$f.part" "$f"
  done
fi
python3 -I "$ROOT/tools/installer_source.py" finalize "$SL" "$DATA/installers/.hashes" || exit 1
for n in $(J 'print "$_\n" for @{$s->{unknown}}'); do
  emit message level "$(json_str warn)" text "$(json_str "$n: no known checksum (a build this project has not seen); used as it is")"
done
echo ">> Revit $YEAR installer ready in installers/revit$YEAR/"
