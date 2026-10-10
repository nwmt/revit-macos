#!/usr/bin/env bash
# One-command install of Autodesk Revit into a CrossOver bottle.
# Usage: ./install.sh <year> [bottle]
#   ./install.sh 2020             → bottle rvt2020-a, app ~/Applications/Revit 2020 (rvt2020-a).app
#   INSTALL_DRYRUN=1 ./install.sh 2026   checks and prints the plan, changes nothing
#   CX_RECREATE=1 ./install.sh 2026      deletes and rebuilds an existing bottle
# Supported: 2020, 2026, 2027. Everything else is untested — see README.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; . "$ROOT/scripts/lib/versions.sh"
YEAR="${1:-}"; BOTTLE="${2:-}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"

case "$YEAR" in
  2020|2026|2027) ;;
  "") sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 1 ;;
  *) echo "Revit $YEAR is not supported yet (expectation: $(revit_expect "$YEAR" 2>/dev/null || echo unknown))." >&2
     echo "Working versions: 2020, 2026, 2027. See README.md." >&2; exit 1 ;;
esac
BOTTLE="${BOTTLE:-$(revit_bottle_default "$YEAR")}"
export REVIT_YEAR="$YEAR"

# ---- preflight: report every problem at once, with the fix ----
missing=0
need() { echo "  ✗ $1"; echo "      fix: $2"; missing=1; }
warn() { echo "  ! $1"; echo "      $2"; }
echo "Checking requirements for Revit $YEAR (bottle $BOTTLE)…"

[ "$(uname -m)" = arm64 ] || need "Apple Silicon Mac required" "this setup is tested on M-series Macs only"
pgrep -q oahd || need "Rosetta 2 is not running" "softwareupdate --install-rosetta --agree-to-license"
[ -x "$CX/bin/cxbottle" ] || need "CrossOver not found in /Applications" "install it from https://www.codeweavers.com/crossover (trial available)"
for t in 7zz:sevenzip winetricks:winetricks cabextract:cabextract gs:ghostscript python3:python3; do
  command -v "${t%%:*}" >/dev/null || need "${t%%:*} not found" "brew install ${t#*:}"
done

SRC="$(revit_installers "$YEAR")"; DST="$(revit_extracted "$YEAR")"
if [ ! -d "$DST" ] && [ -z "$(find "$SRC" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.7z' -o -iname '*.zip' -o -iname '*.iso' \) 2>/dev/null | head -1)" ]; then
  need "no Revit $YEAR installer in installers/revit$YEAR/" "download it from your Autodesk Account, see installers/README.md"
fi
part1=$(find "$SRC" -maxdepth 2 -type f -iname '*_001_0*.sfx.exe' 2>/dev/null | head -1)
if [ ! -d "$DST" ] && [ -n "$part1" ]; then # multi-part download: all parts must be next to each other
  total=$(basename "$part1" | sed -E 's/.*_001_0*([0-9]+)\.sfx\.exe$/\1/')
  have=$(find "$SRC" -maxdepth 2 -type f -iname "*_0*_$(printf '%03d' "$total").sfx.exe" | wc -l | tr -d ' ')
  [ "$have" -eq "$total" ] || need "only $have of $total installer parts in installers/revit$YEAR/" "download all parts from your Autodesk Account"
fi
RX="$ROOT/installers/redist/win7sp1/x64"
[ -f "$RX/msls31.dll" ] || need "installers/redist/win7sp1/x64/msls31.dll missing" "copy C:\\Windows\\System32\\msls31.dll from any Windows 7/10 x64, see installers/README.md"
if [ "$YEAR" = 2020 ]; then
  [ -f "$ROOT/installers/redist/dotNetFx40_Full_x86_x64.exe" ] \
    || need "installers/redist/dotNetFx40_Full_x86_x64.exe missing" ".NET Framework 4.0 offline installer from Microsoft, see installers/README.md"
else
  [ -f "$ROOT/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" ] \
    || warn "no fresh WebView2 runtime in installers/redist/webview2/" \
            "optional but recommended: without it the start screen and Manage Links stay blank (installers/README.md)"
fi

if [ -d "$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE" ] && [ "${CX_RECREATE:-0}" != 1 ]; then
  need "bottle $BOTTLE already exists" "pick another name (./install.sh $YEAR rvt$YEAR-b) or rebuild it: CX_RECREATE=1 ./install.sh $YEAR"
fi
# what Finder and System Settings call "available": includes purgeable space that df does not count
free_gb=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); var r = Ref();
  $.NSURL.fileURLWithPath("/").getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
  Math.floor(ObjC.unwrap(r[0]) / 1e9)' 2>/dev/null) || free_gb=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
[ "${free_gb:-0}" -ge 40 ] || warn "only ${free_gb} GB free" "an install needs up to ~45 GB (installer, extracted files, bottle)"
H="$(hostname)"
grep -qE "[[:space:]]$H([[:space:]]|\$)" /etc/hosts \
  || warn "this Mac's name is not in /etc/hosts — Revit waits ~5 s on every lookup of it" \
          "sudo sh -c 'printf \"127.0.0.1\\t$H\\n::1\\t$H\\n\" >> /etc/hosts'"

[ $missing -eq 0 ] || { echo; echo "Fix the items marked ✗ and run ./install.sh $YEAR again."; exit 1; }
echo "  ✓ ready"

# ---- plan ----
if [ "$YEAR" = 2020 ]; then
  PLAN=("scripts/get-toolchain.sh"
        "scripts/inspect-installer.sh 2020 --extract"
        "scripts/build-bottle.sh $BOTTLE"
        "scripts/make-launcher.sh $BOTTLE 2020")
else
  PLAN=("scripts/get-toolchain.sh"
        "scripts/inspect-installer.sh $YEAR --extract"
        "scripts/cx-bottle.sh $BOTTLE"
        "scripts/install-odis.sh $YEAR $BOTTLE"
        "scripts/make-urlhandler.sh $BOTTLE"
        "scripts/make-launcher.sh $BOTTLE $YEAR")
fi
echo; echo "Plan:"; i=1; for s in "${PLAN[@]}"; do echo "  $i. $s"; i=$((i + 1)); done
[ "${INSTALL_DRYRUN:-0}" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }

# ---- run ----
export CX_DESC="Revit $YEAR"
t0=$SECONDS; i=1
for s in "${PLAN[@]}"; do
  echo; echo "==> [$i/${#PLAN[@]}] $s"
  # shellcheck disable=SC2086 # each plan entry is a script path plus plain words
  "$ROOT"/$s || { echo; echo "Step failed: $s — logs are in logs/. See docs/troubleshooting.md." >&2; exit 1; }
  i=$((i + 1))
done

echo
echo "Done in $(((SECONDS - t0) / 60)) min."
echo "Start Revit from ~/Applications/Revit $YEAR ($BOTTLE).app"
if [ "$YEAR" = 2020 ]; then
  echo "First launch: sign in to Autodesk. If Revit hangs on the splash screen, quit it and start again."
else
  echo "First launch: Revit opens Autodesk sign-in in your browser. After signing in, when the browser asks"
  echo "which app should open the link, choose \"Autodesk Sign-In ($BOTTLE)\"."
fi
case "$YEAR" in 2020|2026) echo "Optional add-ins (RevitLookup, pyRevit): REVIT_YEAR=$YEAR ./scripts/d8-addins.sh $BOTTLE" ;; esac
