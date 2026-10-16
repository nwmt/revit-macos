#!/usr/bin/env bash
# Fetches what the app bundles: 7-Zip, cabextract (built here from source), winetricks and Python, each checked against
# its SHA-256 in app/tools.sh, and the shims release pinned in scripts/lib/shims.sh. Also keeps the 7-Zip and
# cabextract sources for the release. Downloads are cached in dist/app-cache/<sha256>.
# Usage: app/fetch-tools.sh <out folder> [pins file]   → <out>/{bin,python,shims,licenses,sources}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 1 ] || { echo "Usage: app/fetch-tools.sh <out folder> [pins file]" >&2; exit 2; }
PINS="${2:-$ROOT/app/tools.sh}"
. "$ROOT/app/app.conf"; . "$PINS"; . "$ROOT/scripts/lib/shims.sh"
die() { echo "!! $*" >&2; exit 1; }
mkdir -p "$(dirname "$1")"; OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ ! -e "$OUT" ] || { echo "$OUT already exists" >&2; exit 2; }
P="$OUT.partial"; CACHE="$ROOT/dist/app-cache"; PART=""; WORK=""
trap 'rm -rf "$P"; [ -z "$PART" ] || rm -f "$PART"; [ -z "$WORK" ] || rm -rf "$WORK"' EXIT

# the shims first: a release that does not fit these sources must not reach the app (and nothing is downloaded yet)
git -C "$ROOT" rev-parse -q --verify "refs/tags/v$SHIMS_VERSION" >/dev/null || die "no tag v$SHIMS_VERSION: fetch tags (git fetch --tags)"
git -C "$ROOT" diff --quiet "v$SHIMS_VERSION" -- "${SHIMS_SOURCES[@]}" \
  || die "shim sources changed since v$SHIMS_VERSION: tag a shims release first (CONTRIBUTING.md, Releases)"

fetch() { # $1 = URL, $2 = SHA-256 → the checked file in the cache (path on stdout)
  local f="$CACHE/$2" got
  mkdir -p "$CACHE"
  if [ ! -f "$f" ]; then
    echo ">> downloading $1" >&2
    PART="$f.part"; curl -fL --retry 3 -sS -o "$PART" "$1" || die "download failed: $1"
    mv -f "$PART" "$f.new"; PART="$f.new"
  else PART=""; fi
  got="$(shasum -a 256 "${PART:-$f}" | cut -d' ' -f1)"
  if [ "$got" != "$2" ]; then
    rm -f "${PART:-$f}"; PART=""
    die "checksum mismatch: $1
   expected $2
   got      $got"
  fi
  [ -z "$PART" ] || { mv -f "$PART" "$f"; PART=""; }
  echo "$f"
}

rm -rf "$P"; mkdir -p "$P/bin" "$P/sources" "$P/licenses/7-Zip" "$P/licenses/cabextract" "$P/licenses/winetricks" \
  "$P/licenses/Python"
WORK="$(mktemp -d)"

f="$(fetch "$SEVENZIP_URL" "$SEVENZIP_SHA256")"
tar -xJf "$f" -C "$P/bin" 7zz; tar -xJf "$f" -O License.txt > "$P/licenses/7-Zip/License.txt"
f="$(fetch "$SEVENZIP_SRC_URL" "$SEVENZIP_SRC_SHA256")"; cp "$f" "$P/sources/$(basename "$SEVENZIP_SRC_URL")"

f="$(fetch "$CABEXTRACT_URL" "$CABEXTRACT_SHA256")"; cp "$f" "$P/sources/$(basename "$CABEXTRACT_URL")"
tar -xzf "$f" -C "$WORK"; c="$WORK/cabextract-$CABEXTRACT_VERSION"
echo ">> building cabextract $CABEXTRACT_VERSION for macOS $APP_MIN_MACOS" >&2
(cd "$c" && ./configure --disable-dependency-tracking CFLAGS="-O2 -arch arm64 -mmacosx-version-min=$APP_MIN_MACOS" \
  && make) > "$WORK/cabextract.log" 2>&1 || { tail -30 "$WORK/cabextract.log" >&2; die "cabextract did not build"; }
cp "$c/cabextract" "$P/bin/"; cp "$c/COPYING" "$P/licenses/cabextract/"

f="$(fetch "$WINETRICKS_URL" "$WINETRICKS_SHA256")"; cp "$f" "$P/bin/winetricks"; chmod 755 "$P/bin/winetricks"
f="$(fetch "$WINETRICKS_COPYING_URL" "$WINETRICKS_COPYING_SHA256")"; cp "$f" "$P/licenses/winetricks/COPYING"

f="$(fetch "$PYTHON_URL" "$PYTHON_SHA256")"; tar -xzf "$f" -C "$P"   # the archive's top folder is python/
[ -x "$P/python/bin/python3" ] || die "no python/bin/python3 in $PYTHON_URL"
cp "$P/python/lib/python${PYTHON_VERSION%.*}/LICENSE.txt" "$P/licenses/Python/" || die "no CPython LICENSE.txt in $PYTHON_URL"
f="$(fetch "$PYTHON_FULL_URL" "$PYTHON_FULL_SHA256")"   # zstd: bsdtar cannot read it, 7-Zip can
"$P/bin/7zz" x -so "$f" 2>/dev/null | tar -x -C "$WORK" python/licenses python/PYTHON.json || die "cannot read $PYTHON_FULL_URL"
[ -d "$WORK/python/licenses" ] || die "no python/licenses/ in $PYTHON_FULL_URL"
cp -R "$WORK/python/licenses/." "$WORK/python/PYTHON.json" "$P/licenses/Python/"

f="$(fetch "https://github.com/$SHIMS_REPO/releases/download/v$SHIMS_VERSION/revit-macos-shims-$SHIMS_VERSION.zip" "$SHIMS_SHA256")"
unzip -q "$f" -d "$WORK/shims"   # the archive holds build/<shim>/<file> and build/LICENSE
release_complete "$WORK/shims/build" || die "shims release v$SHIMS_VERSION does not hold every shim of SHIMS"
mv "$WORK/shims/build" "$P/shims"

mv "$P" "$OUT"
echo ">> tools in $OUT: 7-Zip $SEVENZIP_VERSION, cabextract $CABEXTRACT_VERSION, winetricks $WINETRICKS_VERSION, Python $PYTHON_VERSION, shims v$SHIMS_VERSION"
