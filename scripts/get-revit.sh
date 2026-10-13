#!/usr/bin/env bash
# Downloads the full Revit <year> installer that an Autodesk "Create Installer" file points to.
# Usage: ./scripts/get-revit.sh <year>
#   needs installers/revit<year>/Create_Installer_RVT_<year>_*_WIN64.exe from your Autodesk Account.
# Autodesk Account now offers only this 32 MB Windows tool. It is a 7z archive whose collection.xml lists
# the same files the old "Browser download" gave (BrowserImageUrl): *_001_002.exe + *_002_002.7z (2025+)
# or *_dlm_001_005.sfx.exe … (2024). That is the base release (e.g. 2026.0); the update in the tool's name
# (2026.5) is a separate package listed in <bundle>/setup_ext.xml → <dir>/setup.xml (Payload, with SHA-256).
# Base files go to installers/revit<year>/, the update to installers/revit<year>/update/; inspect-installer.sh lays
# the update over the extracted base. Resumes an interrupted download; checks the size, and the SHA-256 when known
# (update: from its manifest; base: installers/CHECKSUMS.txt).
set -uo pipefail
YEAR="${1:?specify a year, e.g. 2027}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
SRC="$(revit_installers "$YEAR")"
command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip" >&2; exit 1; }

ci="$(find "$SRC" -maxdepth 1 -type f -iname "Create_Installer_RVT_${YEAR}_*.exe" | sort | tail -1)"
[ -n "$ci" ] || { echo "no Create_Installer_RVT_${YEAR}_*.exe in installers/revit$YEAR/" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
7zz x -y -o"$TMP" "$ci" collection.xml bootstrap.json '*/setup_ext.xml' '*/*/setup.xml' >/dev/null 2>&1
[ -f "$TMP/collection.xml" ] || { echo "$(basename "$ci"): no collection.xml inside — not an Autodesk Create Installer?" >&2; exit 1; }
urls="$(grep -o '<BrowserImageUrl>[^<]*' "$TMP/collection.xml" | head -1 | sed 's/<BrowserImageUrl>//' | tr ';' '\n' | grep .)"
[ -n "$urls" ] || { echo "$(basename "$ci"): lists no full installer (BrowserImageUrl) — please report this" >&2; exit 1; }
# updates: "<url> <size> <sha256> <build>" per package that setup_ext.xml adds
updates="$(python3 -I - "$TMP" <<'PY'
import glob, os, re, sys
for ext in glob.glob(os.path.join(sys.argv[1], "*", "setup_ext.xml")):
    for d in re.findall(r'<Package\s[^>]*sourceDir="([^"]+)"', open(ext, encoding="utf-8").read()):
        s = open(os.path.join(os.path.dirname(ext), d, "setup.xml"), encoding="utf-8").read()
        b = re.search(r"<BuildNumber[^>]*>([^<]+)", s)
        for c, n, u in re.findall(r'<File checkSum="(\w+)" sizePacked="(\d+)"[^>]*>([^<]+)</File>', re.search(r"<Payload.*?</Payload>", s, re.S).group(0)):
            print(u, n, c.lower(), b.group(1) if b else "?")
PY
)"
# only Autodesk's download hosts, only plain file names: the list comes from a file, not from us
while IFS= read -r u; do
  [ -z "$u" ] || [[ "$u" =~ ^https://(efulfillment|dds|up1)\.autodesk\.com/[A-Za-z0-9/._-]+$ ]] || { echo "unexpected download URL: $u" >&2; exit 1; }
done <<<"$urls"$'\n'"$(cut -d' ' -f1 <<<"$updates")"

echo ">> $(basename "$ci"): full installer (the base release), $(wc -l <<<"$urls" | tr -d ' ') file(s)"
[ -n "$updates" ] && while read -r _ _ _ b; do echo "   + update $b"; done <<<"$updates"
need=0; plan=()
all="$(sed 's|$| .|' <<<"$urls")"; [ -n "$updates" ] && all+=$'\n'"$(awk '{print $1, "update"}' <<<"$updates")"
mkdir -p "$SRC/update"
while read -r u sub; do
  f="$SRC/$sub/$(basename "$u")"
  size="$(curl -fsSIL --retry 3 "$u" | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')"
  [ -n "$size" ] || { echo "!! cannot reach $u (offline?)" >&2; exit 1; }
  have="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  if [ "$have" = "$size" ]; then echo "   $(basename "$f"): already here"; continue; fi
  part="$(stat -f %z "$f.part" 2>/dev/null || echo 0)"
  need=$((need + size - part)); plan+=("$u $size $sub")
  echo "   $(basename "$f"): $(((size - part) / 1000000)) MB to download"
done <<<"$all"

if [ ${#plan[@]} -gt 0 ]; then
  # as in install.sh: what Finder calls "available", with purgeable space that df does not count
  free=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); var r = Ref();
    $.NSURL.fileURLWithPath("/").getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
    ObjC.unwrap(r[0])' 2>/dev/null) || free=""
  [[ "$free" =~ ^[0-9]+$ ]] || free=$(df -k "$SRC" | awk 'NR==2 {print $4 * 1024}')
  [ "$free" -gt $((need + 2000000000)) ] || { echo "!! not enough disk space: need $((need / 1000000000 + 2)) GB, free $((free / 1000000000)) GB" >&2; exit 1; }
  for p in "${plan[@]}"; do
    read -r u size sub <<<"$p"; f="$SRC/$sub/$(basename "$u")"
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
[ -n "$updates" ] && while read -r u _ sum _; do
  f="$SRC/update/$(basename "$u")"; echo ">> checking $(basename "$f")"
  echo "$sum  $f" | shasum -a 256 -c --quiet - || { echo "!! $(basename "$f"): checksum mismatch; delete it and run again" >&2; exit 1; }
done <<<"$updates"
echo ">> Revit $YEAR installer ready in installers/revit$YEAR/"
