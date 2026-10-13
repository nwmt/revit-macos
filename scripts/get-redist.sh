#!/usr/bin/env bash
# Downloads the Microsoft runtimes Revit <year> needs from Microsoft, once, into installers/redist/:
#   .NET Framework 4.0 offline installer (2020–2024: .NET Framework 4.7/4.8 goes on top of a real 4.0);
#     the same URL and SHA-256 as winetricks dotnet40.
#   WebView2 Evergreen Standalone x64 (2024+): the one in Revit's installer is too old for Revit (install-odis.sh, step
#     webview2). The link always gives the newest build, so there is no fixed checksum; delete the file to get a newer one.
# A file that is already there is kept. Usage: ./scripts/get-redist.sh <year>
set -uo pipefail
YEAR="${1:?specify a year, e.g. 2024}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
D="$ROOT/installers/redist"

get() { # $1 = url, $2 = file, $3 = sha256 or "" ; download into .part (resumable), rename only after the check
  local url="$1" f="$2" sha="$3"
  if [ -f "$f" ]; then echo "   $(basename "$f"): already here"; return 0; fi
  mkdir -p "$(dirname "$f")"; echo ">> $(basename "$f") from $url"
  curl -fL --retry 5 --retry-delay 5 -C - -o "$f.part" "$url" || { echo "!! download failed; run again to resume" >&2; return 1; }
  if [ -n "$sha" ]; then
    echo "$sha  $f.part" | shasum -a 256 -c --quiet - || { rm -f "$f.part"; echo "!! checksum mismatch, download removed; run again" >&2; return 1; }
  elif [ "$(head -c 2 "$f.part")" != MZ ]; then
    rm -f "$f.part"; echo "!! not a Windows program, download removed; run again" >&2; return 1
  fi
  mv "$f.part" "$f"
}

case "$(revit_dotnet "$YEAR")" in netfx47|netfx48)
  get https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe \
      "$D/dotNetFx40_Full_x86_x64.exe" 65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f || exit 1 ;;
esac
if [ "$YEAR" -ge 2024 ]; then # optional: without it the webview2 step falls back to the runtime in Revit's installer
  get 'https://go.microsoft.com/fwlink/?linkid=2124701' "$D/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" "" \
    || echo "!! no fresh WebView2 runtime: the start screen and Manage Links may stay white (docs/troubleshooting.md)" >&2
fi
exit 0
