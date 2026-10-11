#!/usr/bin/env bash
# Downloads the full Revit <year> installer that an Autodesk "Create Installer" file points to.
# Usage: ./scripts/get-revit.sh <year>
#   needs installers/revit<year>/Create_Installer_RVT_<year>_*_WIN64.exe from your Autodesk Account.
# Autodesk Account now offers only this 32 MB Windows tool. It is a 7z archive whose collection.xml lists
# the same files the old "Browser download" gave (BrowserImageUrl): *_001_002.exe + *_002_002.7z (2025+)
# or *_dlm_001_005.sfx.exe … (2024). We download those into installers/revit<year>/, so the rest of the install
# is unchanged. Resumes an interrupted download; checks the size and, when listed, the SHA-256 in installers/CHECKSUMS.txt.
set -uo pipefail
YEAR="${1:?specify a year, e.g. 2027}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
SRC="$(revit_installers "$YEAR")"
command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip" >&2; exit 1; }

ci="$(find "$SRC" -maxdepth 1 -type f -iname "Create_Installer_RVT_${YEAR}_*.exe" | sort | tail -1)"
[ -n "$ci" ] || { echo "no Create_Installer_RVT_${YEAR}_*.exe in installers/revit$YEAR/" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
7zz e -y -o"$TMP" "$ci" collection.xml bootstrap.json >/dev/null 2>&1
[ -f "$TMP/collection.xml" ] || { echo "$(basename "$ci"): no collection.xml inside — not an Autodesk Create Installer?" >&2; exit 1; }
name="$(grep -o '"productDisplayName":"[^"]*"' "$TMP/bootstrap.json" 2>/dev/null | cut -d'"' -f4)"
urls="$(grep -o '<BrowserImageUrl>[^<]*' "$TMP/collection.xml" | head -1 | sed 's/<BrowserImageUrl>//' | tr ';' '\n' | grep .)"
[ -n "$urls" ] || { echo "$(basename "$ci"): lists no full installer (BrowserImageUrl) — please report this" >&2; exit 1; }
# only Autodesk's download hosts, only plain file names: the list comes from a file, not from us
while IFS= read -r u; do
  [[ "$u" =~ ^https://(efulfillment|dds)\.autodesk\.com/[A-Za-z0-9/._-]+$ ]] || { echo "unexpected download URL: $u" >&2; exit 1; }
done <<<"$urls"

echo ">> $(basename "$ci"): full installer (the base release), $(wc -l <<<"$urls" | tr -d ' ') file(s)"
need=0; plan=()
while IFS= read -r u; do
  f="$SRC/$(basename "$u")"
  size="$(curl -fsSIL --retry 3 "$u" | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')"
  [ -n "$size" ] || { echo "!! cannot reach $u (offline?)" >&2; exit 1; }
  have="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  if [ "$have" = "$size" ]; then echo "   $(basename "$f"): already here"; continue; fi
  part="$(stat -f %z "$f.part" 2>/dev/null || echo 0)"
  need=$((need + size - part)); plan+=("$u $size")
  echo "   $(basename "$f"): $(((size - part) / 1000000)) MB to download"
done <<<"$urls"

if [ ${#plan[@]} -gt 0 ]; then
  free=$(df -k "$SRC" | awk 'NR==2 {print $4 * 1024}')
  [ "$free" -gt $((need + 2000000000)) ] || { echo "!! not enough disk space: need $((need / 1000000000 + 2)) GB, free $((free / 1000000000)) GB" >&2; exit 1; }
  for p in "${plan[@]}"; do
    u="${p% *}"; size="${p##* }"; f="$SRC/$(basename "$u")"
    echo ">> $(basename "$f") ($((size / 1000000)) MB)"
    # into .part first: a half-downloaded file must not look finished to install.sh; -C - resumes it
    for try in 1 2 3 4 5; do
      curl -fL --retry 5 --retry-delay 5 -C - -o "$f.part" "$u" && break
      echo "   download interrupted, resuming ($try/5)…"; sleep 5
    done
    [ "$(stat -f %z "$f.part" 2>/dev/null || echo 0)" = "$size" ] || { echo "!! $(basename "$f"): incomplete; run again to resume" >&2; exit 1; }
    mv "$f.part" "$f"
  done
fi

# known checksums (installers/CHECKSUMS.txt) for the files we have
while IFS= read -r u; do
  f="$SRC/$(basename "$u")"
  sum="$(awk -v p="revit$YEAR/$(basename "$u")" '$2 == p {print $1}' "$ROOT/installers/CHECKSUMS.txt" 2>/dev/null)"
  [ -n "$sum" ] || continue
  echo ">> checking $(basename "$f")"
  echo "$sum  $f" | shasum -a 256 -c --quiet - || { echo "!! $(basename "$f"): checksum mismatch; delete it and run again" >&2; exit 1; }
done <<<"$urls"
echo ">> Revit $YEAR installer ready in installers/revit$YEAR/"
