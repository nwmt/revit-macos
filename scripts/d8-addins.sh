#!/usr/bin/env bash
# D8: Revit add-ins (RevitLookup, pyRevit). 2020 runs them on the stock .NET 4.7; 2023 on .NET 4.8; 2026 on Revit's own .NET 8.
# Usage: [REVIT_YEAR=2026] ./scripts/d8-addins.sh <bottle> [steps...]   (default year 2020)
#   default steps: revitlookup pyrevit check (2023, 2026: + wpfsw)
#   net472 / net48 — available, but Revit 2020 crashes in clr.dll on them; don't use
#   enscape-off / enscape-on — remove/restore the Enscape manifest (Start crashes Revit)
#   wpfsw / wpfhw — software-rendered WPF (fixes black boxes from add-in windows) / revert
#   check — only show state (.NET Release, .addin manifests)
# Requires (installers/, see CHECKSUMS.txt):
#   redist/dotnet472/ndp472-KB4054530-x86-x64-AllOS-ENU.exe — net472 step only
#   redist/dotnet48/ndp48-x86-x64-allos-enu.exe          — net48 step only
#   addins/revitlookup/RevitLookup-2020.0.0.3-SingleUser.msi — last build for 2020 (release 2023.1.0-EOL)
#   addins/enscape/Enscape-3.4.4-94564.msi                — enscape step (not default; bring your own)
#   redist/nuget/system.valuetuple.4.5.0.nupkg           — for the enscape step (nuget.org)
#   addins/pyrevit48/pyRevit_4.8.12.22247_signed.exe     — the IPY277 engine works on .NET 4.7 (6.5.5 doesn't)
#   2023: addins/revitlookup/RevitLookup-2023.5.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
#   2026: addins/revitlookup/RevitLookup-2026.1.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
set -uo pipefail

NAME="${1:?specify a bottle}"; shift
YEAR="${REVIT_YEAR:-2020}"
STEPS=("$@"); [ ${#STEPS[@]} -eq 0 ] && { STEPS=(revitlookup pyrevit check); case "$YEAR" in 2023|2026) STEPS=(revitlookup pyrevit wpfsw check);; esac; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
I="$ROOT/installers"
LOGDIR="$ROOT/logs/d8-$NAME-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
ADDINS="$B/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Addins/$YEAR"
w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
run_copy() { # $1 = source, $2 = name in C:\, rest = switches; exit code in $RC
  cp "$1" "$B/drive_c/$2"
  w "C:\\$2" "${@:3}" >>"$LOGDIR/wine.log" 2>&1; RC=$?
  rm -f "$B/drive_c/$2"
}
net_release() { w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>/dev/null | tr -d '\r' | awk '/Release/{print $3}' | xargs printf '%d\n' 2>/dev/null; }

[ -d "$B" ] || { echo "no bottle $NAME" >&2; exit 1; }
case "$YEAR" in
  2020) LOOKUP="$I/addins/revitlookup/RevitLookup-2020.0.0.3-SingleUser.msi"   # last build for 2020 (2023.1.0-EOL)
        PYRSETUP="$I/addins/pyrevit48/pyRevit_4.8.12.22247_signed.exe";;
  2023) LOOKUP="$I/addins/revitlookup/RevitLookup-2023.5.4-SingleUser.msi"   # GitHub release 2027.0.4
        PYRSETUP="$I/addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe";;
  2026) LOOKUP="$I/addins/revitlookup/RevitLookup-2026.1.4-SingleUser.msi"
        PYRSETUP="$I/addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe";;
  *) echo "d8: year $YEAR is not configured" >&2; exit 1;;
esac
echo ">> logs: $LOGDIR"

for s in "${STEPS[@]}"; do
  t0=$(date +%s)
  case "$s" in
  net48|net472)
    # net48: Revit 2020 crashes on startup with it (clr.dll AV, 80131506) — don't use.
    # Like 4.7 in d3: on win10 the installer treats 4.8/4.7.2 as built in and silently exits — install as win7.
    echo ">> $s: before $(net_release)"
    case "$s" in net48) SRC="$I/redist/dotnet48/ndp48-x86-x64-allos-enu.exe";;
                 net472) SRC="$I/redist/dotnet472/ndp472-KB4054530-x86-x64-AllOS-ENU.exe";; esac
    w winecfg -v win7 >>"$LOGDIR/wine.log" 2>&1
    WINEDLLOVERRIDES="fusion=b" run_copy "$SRC" ndp.exe /q /norestart /log 'C:\net48-setup'
    w winecfg -v win10 >>"$LOGDIR/wine.log" 2>&1
    w wineboot -r >>"$LOGDIR/wine.log" 2>&1   # MSI asks for a reboot (pending file renames)
    cp "$B"/drive_c/net48-setup* "$LOGDIR/" 2>/dev/null; rm -f "$B"/drive_c/net48-setup*
    # exit code is truncated to a byte: 3010 (reboot needed) arrives as 194
    echo "   $s exit=$RC (0, 194 = 3010 — success), Release=$(net_release) (461808 = 4.7.2, 528040+ = 4.8)  $(( $(date +%s) - t0 ))s"
    ;;
  revitlookup)
    cp "$LOOKUP" "$B/drive_c/RevitLookup.msi"
    w msiexec /i 'C:\RevitLookup.msi' /qn /l*v 'C:\d8-revitlookup.log' >>"$LOGDIR/wine.log" 2>&1; RC=$?
    rm -f "$B/drive_c/RevitLookup.msi"; mv "$B/drive_c/d8-revitlookup.log" "$LOGDIR/" 2>/dev/null
    echo "   revitlookup exit=$RC  $(( $(date +%s) - t0 ))s"
    ;;
  pyrevit)
    # pyRevit 4.8.12, IPY277 engine — IronPython 2.7.7 without Expression.Compile(bool).
    # 6.5.5 won't do: IPY2712PR needs .NET 4.7.1+, IPY342 needs System.Memory 4.0.1.2; Revit crashes on 4.7.2/4.8.
    # The installer calls `attach master 277 --installed` but doesn't find Revit — attach explicitly (manifest in ProgramData).
    run_copy "$PYRSETUP" pyRevit-setup.exe \
      /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- '/LOG=C:\d8-pyrevit.log'
    mv "$B/drive_c/d8-pyrevit.log" "$LOGDIR/" 2>/dev/null
    PYR='C:\users\crossover\AppData\Roaming\pyRevit-Master\bin\pyrevit.exe'
    [ "$YEAR" = 2020 ] && w "$PYR" attach master 277 2020 >>"$LOGDIR/wine.log" 2>&1
    echo "   pyrevit exit=$RC  $(( $(date +%s) - t0 ))s"; w "$PYR" attached 2>/dev/null | tr -d '\r' | sed 's/^/   /'
    ;;
  wpfsw|wpfhw)
    # Add-in windows (pyRevit, RevitLookup) use WPF effects: their D3D9 shaders fail to compile via DXVK → MoltenVK
    # ("DxvkGraphicsPipeline: Failed to compile pipeline") → black rectangles all over Revit. wpfsw makes WPF render
    # in software (standard Windows key), bypassing the GPU; Revit viewports are unaffected. wpfhw reverts it.
    K='HKCU\Software\Microsoft\Avalon.Graphics'
    if [ "$s" = wpfsw ]; then w reg add "$K" /v DisableHWAcceleration /t REG_DWORD /d 1 /f >>"$LOGDIR/wine.log" 2>&1
    else w reg delete "$K" /v DisableHWAcceleration /f >>"$LOGDIR/wine.log" 2>&1; fi
    echo "   $s: $(w reg query "$K" /v DisableHWAcceleration 2>/dev/null | tr -d '\r' | awk '/DisableHW/{print $3}')"
    ;;
  enscape)
    # Enscape 3.4.4 (Revit 2019–2023); without UI the MSI needs ACCEPTEULA=1 (LaunchCondition, otherwise silent exit 67 = 1603).
    # ACCEPTEULA=1 accepts the Enscape EULA — run this step only if you accept it.
    cp "$I/addins/enscape/Enscape-3.4.4-94564.msi" "$B/drive_c/Enscape.msi"
    w msiexec /i 'C:\Enscape.msi' /qn /norestart ACCEPTEULA=1 '/l*v' 'C:\d8-enscape.log' >>"$LOGDIR/wine.log" 2>&1; RC=$?
    rm -f "$B/drive_c/Enscape.msi"; mv "$B/drive_c/d8-enscape.log" "$LOGDIR/" 2>/dev/null
    # Enscape ships System.ValueTuple 4.0.3.0 with its own types (net461 build). On .NET 4.7 ValueTuple is already
    # in mscorlib → two distinct types → TypeLoadException "does not have an implementation" when the plugin starts (grey
    # icons). On 4.7.2+ the runtime substitutes it itself. Drop in the net47 facade from the same NuGet package (type forwards).
    VT="$B/drive_c/Program Files/Enscape/Bin64/System.ValueTuple.dll"
    [ -f "$VT.orig" ] || cp "$VT" "$VT.orig"
    unzip -p "$I/redist/nuget/system.valuetuple.4.5.0.nupkg" lib/net47/System.ValueTuple.dll > "$VT"
    echo "   enscape exit=$RC; System.ValueTuple → net47 facade ($(wc -c <"$VT" | tr -d ' ') bytes)  $(( $(date +%s) - t0 ))s"
    ;;
  enscape-off|enscape-on)
    # Enscape Start crashes Revit — move the 2020 manifest to Addins\2020.off, leave the files alone.
    AD="$B/drive_c/ProgramData/Autodesk/Revit/Addins/2020"; mkdir -p "$AD.off"
    if [ "$s" = enscape-off ]; then mv "$AD/0_Enscape.addin" "$AD.off/" 2>/dev/null; else mv "$AD.off/0_Enscape.addin" "$AD/" 2>/dev/null; fi
    echo "   $s: $(ls "$AD"/0_Enscape.addin 2>/dev/null || echo 'manifest disabled')"
    ;;
  check)
    echo ">> check: .NET Release=$(net_release)"
    ls "$ADDINS"/*.addin "$B/drive_c/ProgramData/Autodesk/Revit/Addins/$YEAR"/*.addin 2>/dev/null | sed "s|$B/||; s|^|   |"
    ;;
  *) echo "unknown step $s" >&2; exit 1;;
  esac
done
