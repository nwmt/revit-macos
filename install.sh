#!/usr/bin/env bash
# One-command install of Autodesk Revit into a CrossOver bottle.
# Usage: ./install.sh <year> [bottle]
#   ./install.sh 2020             → bottle rvt2020-a, app ~/Applications/Revit 2020 (rvt2020-a).app
#   INSTALL_DRYRUN=1 ./install.sh 2026   checks and prints the plan, changes nothing
#   CX_RECREATE=1 ./install.sh 2026 [bottle]   deletes and rebuilds an existing bottle
# Supported: 2020, 2023, 2024, 2025, 2026, 2027. Everything else is untested — see README.md.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; . "$ROOT/scripts/lib/versions.sh"
YEAR="${1:-}"; BOTTLE="${2:-}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"

case "$YEAR" in
  2020|2023|2024|2025|2026|2027) ;;
  "") sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 1 ;;
  *) echo "Revit $YEAR is not supported yet (expectation: $(revit_expect "$YEAR" 2>/dev/null || echo unknown))." >&2
     echo "Working versions: 2020, 2023, 2024, 2025, 2026, 2027. See README.md." >&2; exit 1 ;;
esac
BOTTLE="${BOTTLE:-$(revit_bottle_default "$YEAR")}"
# the name ends up in shell commands, AppleScript and app names: keep it plain
[[ "$BOTTLE" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Bottle name may contain only letters, digits, - and _: \"$BOTTLE\"" >&2; exit 1; }
export REVIT_YEAR="$YEAR"

# ---- preflight: report every problem at once, with the fix ----
missing=0
need() { echo "  ✗ $1"; echo "      fix: $2"; missing=1; }
warn() { echo "  ! $1"; echo "      $2"; }
echo "Checking requirements for Revit $YEAR (bottle $BOTTLE)…"

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
  need "Apple Silicon Mac required" "this setup is tested on M-series Macs only"
elif [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
  need "this Terminal runs under Rosetta" "quit Terminal, turn off \"Open using Rosetta\" in its Get Info window, and run again"
fi
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || need "Rosetta 2 is not installed" "softwareupdate --install-rosetta --agree-to-license"
[ -x "$CX/bin/cxbottle" ] || need "CrossOver not found in /Applications" "install it from https://www.codeweavers.com/crossover (trial available)"
for t in 7zz:sevenzip winetricks:winetricks cabextract:cabextract gs:ghostscript python3:python3; do
  command -v "${t%%:*}" >/dev/null || need "${t%%:*} not found" "brew install ${t#*:}"
done

SRC="$(revit_installers "$YEAR")"; DST="$(revit_extracted "$YEAR")"
# Autodesk Account now gives only "Create Installer": scripts/get-revit.sh downloads the full installer it points to
GET=""; [ ! -d "$DST" ] && [ -n "$(find "$SRC" -maxdepth 1 -type f -iname "Create_Installer_RVT_${YEAR}_*.exe" 2>/dev/null | head -1)" ] \
  && GET="scripts/get-revit.sh $YEAR"
if [ ! -d "$DST" ] && [ -z "$(find "$SRC" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.7z' -o -iname '*.zip' -o -iname '*.iso' \) 2>/dev/null | head -1)" ]; then
  need "no Revit $YEAR installer in installers/revit$YEAR/" "download it from your Autodesk Account, see installers/README.md"
fi
part1=$(find "$SRC" -maxdepth 2 -type f -iname '*_001_0*.sfx.exe' 2>/dev/null | head -1)
if [ ! -d "$DST" ] && [ -z "$GET" ] && [ -n "$part1" ]; then # multi-part download (2020, 2023): every part 001…NNN of the same download
  total=$(basename "$part1" | sed -E 's/.*_001_0*([0-9]+)\.sfx\.exe$/\1/'); stem="${part1%_001_*}"; tot3=$(printf '%03d' "$total")
  gone=""; for n in $(seq -f '%03g' 1 "$total"); do [ -f "${stem}_${n}_${tot3}.sfx.exe" ] || gone+=" $n"; done
  [ -z "$gone" ] || need "installer parts missing in installers/revit$YEAR/:$gone (of $tot3)" "download all parts from your Autodesk Account"
fi
if [ ! -d "$DST" ] && [ -z "$GET" ] && [ -z "$part1" ] && [ -z "$(find "$SRC" -maxdepth 2 -type f -iname '*.7z' 2>/dev/null | head -1)" ]; then
  need "no .7z payload in installers/revit$YEAR/ (the small .exe alone is only the downloader)" \
       "download both files of the Autodesk download, see versions/$YEAR.md"
fi
RX="$ROOT/installers/redist/win7sp1/x64"
[ -f "$RX/msls31.dll" ] || need "installers/redist/win7sp1/x64/msls31.dll missing" "copy C:\\Windows\\System32\\msls31.dll from any Windows 7/10 x64, see installers/README.md"
case "$(revit_dotnet "$YEAR")" in netfx47|netfx48) # .NET Framework 4.7/4.8 goes on top of a real 4.0
  [ -f "$ROOT/installers/redist/dotNetFx40_Full_x86_x64.exe" ] \
    || need "installers/redist/dotNetFx40_Full_x86_x64.exe missing" ".NET Framework 4.0 offline installer from Microsoft, see installers/README.md" ;;
esac
if [ "$YEAR" -ge 2024 ]; then
  [ -f "$ROOT/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe" ] \
    || warn "no fresh WebView2 runtime in installers/redist/webview2/" \
            "optional but recommended: without it the start screen and Manage Links stay blank (installers/README.md)"
fi

if [ -d "$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE" ] && [ "${CX_RECREATE:-0}" != 1 ]; then
  need "bottle $BOTTLE already exists" "pick another name (./install.sh $YEAR rvt$YEAR-b) or rebuild it: CX_RECREATE=1 ./install.sh $YEAR $BOTTLE"
fi
# what Finder and System Settings call "available": includes purgeable space that df does not count
free_gb=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); var r = Ref();
  $.NSURL.fileURLWithPath("/").getResourceValueForKeyError(r, $.NSURLVolumeAvailableCapacityForImportantUsageKey, null);
  Math.floor(ObjC.unwrap(r[0]) / 1e9)' 2>/dev/null) || free_gb=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
if [ -n "$GET" ]; then [ "${free_gb:-0}" -ge 55 ] || warn "only ${free_gb} GB free" "an install that downloads Revit needs up to ~55 GB (download, extracted files, bottle)"
else [ "${free_gb:-0}" -ge 40 ] || warn "only ${free_gb} GB free" "an install needs up to ~45 GB (installer, extracted files, bottle)"; fi
H="$(hostname)"
grep -qE "[[:space:]]$H([[:space:]]|\$)" /etc/hosts \
  || warn "this Mac's name is not in /etc/hosts — Revit waits ~5 s on every lookup of it" \
          "sudo sh -c 'printf \"127.0.0.1\\t$H\\n::1\\t$H\\n\" >> /etc/hosts'"

[ $missing -eq 0 ] || { echo; echo "Fix the items marked ✗ and run ./install.sh $YEAR again."; exit 1; }
echo "  ✓ ready"

# ---- plan ----
if [ "$YEAR" = 2020 ]; then
  PLAN=("scripts/get-shims.sh"
        "scripts/inspect-installer.sh 2020 --extract"
        "scripts/build-bottle.sh $BOTTLE"
        "scripts/make-launcher.sh $BOTTLE 2020")
elif [ "$YEAR" = 2023 ]; then # sign-in in Revit's own window (AdSSO): no link handler
  PLAN=("scripts/get-shims.sh"
        "scripts/inspect-installer.sh 2023 --extract"
        "scripts/cx-bottle.sh $BOTTLE"
        "scripts/install-odis.sh 2023 $BOTTLE"
        "scripts/make-launcher.sh $BOTTLE 2023")
else
  PLAN=("scripts/get-shims.sh"
        "scripts/inspect-installer.sh $YEAR --extract"
        "scripts/cx-bottle.sh $BOTTLE"
        "scripts/install-odis.sh $YEAR $BOTTLE"
        "scripts/make-urlhandler.sh $BOTTLE"
        "scripts/make-launcher.sh $BOTTLE $YEAR")
fi
[ -n "$GET" ] && PLAN=("${PLAN[0]}" "$GET" "${PLAN[@]:1}") # download before extracting
echo; echo "Plan:"; i=1; for s in "${PLAN[@]}"; do echo "  $i. $s"; i=$((i + 1)); done
[ "${INSTALL_DRYRUN:-0}" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }

# ---- run ----
export CX_DESC="Revit $YEAR"
t0=$SECONDS; i=1
for s in "${PLAN[@]}"; do
  echo; echo "==> [$i/${#PLAN[@]}] $s"
  # shellcheck disable=SC2086
  # entries are a script path plus plain words (the bottle name is validated above)
  "$ROOT"/$s || {
    last="$(ls -td "$ROOT"/logs/* 2>/dev/null | head -1)"; [ -d "$last" ] && last="$last/summary.txt"
    echo; echo "Step failed: $s" >&2
    [ -f "$last" ] && { echo "Last log: $last" >&2; tail -15 "$last" | sed 's/^/  | /' >&2; }
    echo "See docs/troubleshooting.md. To start over: CX_RECREATE=1 ./install.sh $YEAR $BOTTLE" >&2
    exit 1
  }
  i=$((i + 1))
done

# installers report errors in their own way; check the result instead of trusting exit codes
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
if [ ! -f "$(revit_dir_unix "$B" "$YEAR")/Revit.exe" ]; then
  echo; echo "Install finished, but Revit.exe is not in the bottle. Logs: logs/. To start over: CX_RECREATE=1 ./install.sh $YEAR $BOTTLE" >&2
  exit 1
fi
sum="$(ls -td "$ROOT"/logs/{d6,install}-"$BOTTLE"-*/ 2>/dev/null | head -1)summary.txt"
# not problems: a running service, and AdskLicensing's 84 (its service can't start under Wine; the licensing step fixes that up)
if [ -f "$sum" ] && bad="$(grep -E 'exit=' "$sum" | grep -Ev 'exit=(0|3010|skip|ok|RUNNING)[[:space:]]|^ *licensing +exit=84 ')"; then
  echo; echo "Some steps reported problems (Revit may still work; details in $sum):"; printf '%s\n' "$bad" | sed 's/^/  /'
fi

echo
echo "Done in $(((SECONDS - t0) / 60)) min."
echo "Start Revit from ~/Applications/Revit $YEAR ($BOTTLE).app"
[ -d "$HOME/Applications/Revit Viewer $YEAR ($BOTTLE).app" ] && echo "Revit Viewer (free, no license needed): ~/Applications/Revit Viewer $YEAR ($BOTTLE).app"
if [ "$YEAR" = 2020 ] || [ "$YEAR" = 2023 ]; then
  echo "First launch: sign in to Autodesk. If Revit hangs on the splash screen, quit it and start again."
else
  echo "First launch: Revit opens Autodesk sign-in in your browser. After signing in, when the browser asks"
  echo "which app should open the link, choose \"Autodesk Sign-In ($BOTTLE)\"."
fi
case "$YEAR" in 2020|2023|2025|2026) echo "Optional add-ins (RevitLookup, pyRevit): REVIT_YEAR=$YEAR ./scripts/d8-addins.sh $BOTTLE" ;; esac
