#!/usr/bin/env bash
# x64 RichEdit (riched20/riched32/msftedit + usp10) from the Windows 7 SP1 x64 package (same URL and sha256 as winetricks).
# → installers/redist/win7sp1/x64/. The ~947 MB package is downloaded once.
# NOTE: riched20/msftedit delay-load msls31.dll (Line Services); SP1 has no x64 build of it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; lock_take "get-win7-richedit.sh"
D="$ROOT/installers/redist/win7sp1"; mkdir -p "$D/x64"; cd "$D"
PKG=windows6.1-KB976932-X64.exe
SHA=f4d1d418d91b1619688a482680ee032ffd2b65e420c6d2eaecf8aa3762aa64c8
# download into .part (resumable), rename only after the checksum matches
if [ ! -f "$PKG" ]; then
  curl -fL --retry 5 -C - -o "$PKG.part" \
    'http://download.windowsupdate.com/msdownload/update/software/svpk/2011/02/windows6.1-kb976932-x64_74865ef2562006e51d7f9333b4a8d45b7a749dab.exe'
  echo "$SHA  $PKG.part" | shasum -a 256 -c || { rm -f "$PKG.part"; echo "checksum mismatch, download removed; run again" >&2; exit 1; }
  mv "$PKG.part" "$PKG"
fi
echo "$SHA  $PKG" | shasum -a 256 -c || { rm -f "$PKG"; echo "corrupt $PKG removed; run again" >&2; exit 1; }
for f in \
  'amd64_microsoft-windows-riched32_31bf3856ad364e35_6.1.7601.17514_none_fb26b945993b2f11/riched20.dll' \
  'amd64_microsoft-windows-riched32_31bf3856ad364e35_6.1.7601.17514_none_fb26b945993b2f11/riched32.dll' \
  'amd64_microsoft-windows-msftedit_31bf3856ad364e35_6.1.7601.17514_none_33f6fe754dd11735/msftedit.dll' \
  'amd64_microsoft-windows-usp_31bf3856ad364e35_6.1.7601.17514_none_0b207e7d6f1bea6f/usp10.dll'; do
  cabextract -q -d tmp -F "$f" "$PKG" && cp "tmp/$f" x64/
done
rm -rf tmp; ls -la x64
