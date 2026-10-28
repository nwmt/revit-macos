#!/usr/bin/env bash
# dpapi.exe under real Wine, in a throwaway bottle (rvt-dpapi-test): a protect → unprotect round trip gives the same
# text; a missing or garbage file gives exit 1/2 with nothing on stdout. Not part of the default suites: it needs
# CrossOver and takes about a minute. Exit 77 = skipped (no CrossOver or no build/dpapi/dpapi.exe).
# Usage: tests/wine-dpapi.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CX="${REVIT_CX:-/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}"
NAME=rvt-dpapi-test; EXE="$REPO/build/dpapi/dpapi.exe"
[ -x "$CX/bin/cxbottle" ] || { echo "SKIP: no CrossOver"; exit 77; }
[ -f "$EXE" ] || { echo "SKIP: no build/dpapi/dpapi.exe (./scripts/build-shims.sh dpapi)"; exit 77; }
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
[ ! -e "$B" ] || { echo "a bottle $NAME exists already: delete it first"; exit 1; }
cleanup() { WINEPREFIX="$B" "$CX/bin/wineserver" -k 2>/dev/null; "$CX/bin/cxbottle" --bottle "$NAME" --delete --force >/dev/null 2>&1; }
trap cleanup EXIT
"$CX/bin/cxbottle" --bottle "$NAME" --create --template win10_64 >/dev/null 2>&1 </dev/null || { echo "cannot create $NAME"; exit 1; }
cp "$EXE" "$B/drive_c/dpapi.exe" && printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$B/drive_c/plain.txt" \
  && head -c 200 /dev/urandom > "$B/drive_c/garbage.bin" || exit 1
n=0; fails=0
run() { OUT="$("$CX/bin/wine" --bottle "$NAME" 'C:\dpapi.exe' "$@" 2>"$B/drive_c/err.txt" </dev/null)"; RC=$?; ERR="$(cat "$B/drive_c/err.txt")"; }
check() { n=$((n + 1)); if eval "$2"; then echo "ok   $1"; else echo "FAIL $1 (rc=$RC out=${OUT:0:80} err=$ERR)"; fails=$((fails + 1)); fi; }
run protect 'C:\plain.txt' 'C:\blob.bin'; check "protect writes the blob" '[ "$RC" = 0 ] && [ -s "$B/drive_c/blob.bin" ]'
check "the blob is not the plaintext" '! cmp -s "$B/drive_c/blob.bin" "$B/drive_c/plain.txt"'
run unprotect 'C:\blob.bin'; check "unprotect gives the same text, stderr empty" '[ "$RC" = 0 ] && [ "$OUT" = "$(cat "$B/drive_c/plain.txt")" ] && [ -z "$ERR" ]'
run unprotect 'C:\missing.bin'; check "missing file: exit 1, stdout empty" '[ "$RC" = 1 ] && [ -z "$OUT" ] && [ -n "$ERR" ]'
run unprotect 'C:\garbage.bin'; check "garbage: exit 2, stdout empty" '[ "$RC" = 2 ] && [ -z "$OUT" ] && [ -n "$ERR" ]'
run; check "usage: exit 2" '[ "$RC" = 2 ] && [ -z "$OUT" ]'
echo; echo "$((n - fails))/$n passed"
[ "$fails" = 0 ]
