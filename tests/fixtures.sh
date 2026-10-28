#!/usr/bin/env bash
# Third-party files the tests compare our patches against, fetched once and checked by sha256 (they are not ours to
# commit: pyRevit is GPL-3, the MCP extension is MIT under its own copyright).
# Usage: tests/fixtures.sh <url> <sha256> <name>  → prints the cached file's path. Exit 77: no network (the caller
# skips with a visible SKIP line); 1: the download does not match the pin.
set -uo pipefail
[ $# = 3 ] || { echo "Usage: tests/fixtures.sh <url> <sha256> <name>" >&2; exit 2; }
url="$1"; sha="$2"; name="$3"
dir="${REVIT_TEST_CACHE:-$HOME/Library/Caches/revit-macos-tests}"; f="$dir/$name"
have() { [ -f "$f" ] && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ]; }
if ! have; then
  mkdir -p "$dir" || exit 1
  curl -sfL --max-time 60 -o "$f.part" "$url" || { rm -f "$f.part"; exit 77; }
  mv -f "$f.part" "$f"
  have || { echo "$name: sha256 is not $sha" >&2; rm -f "$f"; exit 1; }
fi
echo "$f"
