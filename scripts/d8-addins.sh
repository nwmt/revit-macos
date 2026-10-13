#!/usr/bin/env bash
# D8: Revit add-ins (RevitLookup, pyRevit). 2020 runs them on the stock .NET 4.7; 2023, 2024 on .NET 4.8; 2025, 2026 on Revit's own .NET (8, or 10 after the .5 update).
# 2027: only trust and check (RevitLookup and pyRevit are not set up for it).
# Usage: [REVIT_YEAR=2026] ./scripts/d8-addins.sh <bottle> [steps...]   (default year 2020)
#   default steps: revitlookup pyrevit trust check (2023–2026: + wpfsw)
#   trust — trust the publishers of the add-ins in your Addins\<year> folder, as "Always Load" does (under Wine Revit
#           can't save that choice and asks on every start); trust is per publisher, so it covers their other add-ins too
#   net472 / net48 — available, but Revit 2020 crashes in clr.dll on them; don't use
#   enscape — Enscape with its fixes (not default: bring your own installer): 3.4.4 for Revit 2020, 4.18 LTS for 2027
#   enscape-off / enscape-on — remove/restore the Enscape manifest (Enscape does not load / loads again)
#   wpfsw / wpfhw — software-rendered WPF (fixes black boxes from add-in windows) / revert
#   check — only show state (.NET Release, .addin manifests)
# Requires (installers/, see CHECKSUMS.txt):
#   redist/dotnet472/ndp472-KB4054530-x86-x64-AllOS-ENU.exe — net472 step only
#   redist/dotnet48/ndp48-x86-x64-allos-enu.exe          — net48 step only
#   addins/revitlookup/RevitLookup-2020.0.0.3-SingleUser.msi — last build for 2020 (release 2023.1.0-EOL)
#   addins/enscape/Enscape-3.4.4-94564.msi                — enscape step, 2020 (not default; bring your own)
#   addins/enscape/Enscape-4.18.2.1657-lts.exe            — enscape step, 2027 (not default; bring your own)
#   redist/nuget/system.valuetuple.4.5.0.nupkg           — for the enscape step (nuget.org)
#   addins/pyrevit48/pyRevit_4.8.12.22247_signed.exe     — the IPY277 engine works on .NET 4.7 (6.5.5 doesn't)
#   2023: addins/revitlookup/RevitLookup-2023.5.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
#   2024: addins/revitlookup/RevitLookup-2024.3.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
#   2025: addins/revitlookup/RevitLookup-2025.2.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
#   2026: addins/revitlookup/RevitLookup-2026.1.4-SingleUser.msi, addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe
set -uo pipefail

NAME="${1:?specify a bottle}"; shift
YEAR="${REVIT_YEAR:-2020}"
STEPS=("$@"); [ ${#STEPS[@]} -eq 0 ] && { STEPS=(revitlookup pyrevit trust check); case "$YEAR" in 2023|2024|2025|2026) STEPS=(revitlookup pyrevit trust wpfsw check);; 2027) STEPS=(trust check);; esac; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
I="$ROOT/installers"
LOGDIR="$ROOT/logs/d8-$NAME-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
ADDINS="$B/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Addins/$YEAR"
ALLADDINS=("$B/drive_c/ProgramData/Autodesk/Revit/Addins/$YEAR" "$B/drive_c/Program Files/Autodesk/Revit/Addins/$YEAR") # all users; the second since 2027
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
  2024) LOOKUP="$I/addins/revitlookup/RevitLookup-2024.3.4-SingleUser.msi"   # GitHub release 2027.0.4
        PYRSETUP="$I/addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe";;
  2025) LOOKUP="$I/addins/revitlookup/RevitLookup-2025.2.4-SingleUser.msi"     # GitHub release 2027.0.4
        PYRSETUP="$I/addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe";;
  2026) LOOKUP="$I/addins/revitlookup/RevitLookup-2026.1.4-SingleUser.msi"
        PYRSETUP="$I/addins/pyrevit7/pyRevit_7.0.0.26278_signed.exe";;
  2027) LOOKUP=""; PYRSETUP="";;
  *) echo "d8: year $YEAR is not configured" >&2; exit 1;;
esac
echo ">> logs: $LOGDIR"

enscape4() { # Enscape 4.18 LTS for Revit 2027; the renderer runs in its own process, Enscape.RendererHost.exe
  local S32="$B/drive_c/windows/system32" A='HKCU\Software\Wine\AppDefaults\Enscape.RendererHost.exe\DllOverrides'
  command -v 7zz >/dev/null || { echo "enscape: 7zz required: brew install sevenzip" >&2; return 1; }
  # Chaos Installer without UI: -auto installs the default set (Enscape, Chaos Unified Login, Cosmos, ...).
  # -auto accepts the Enscape EULA — run this step only if you accept it.
  cp "$I/addins/enscape/Enscape-4.18.2.1657-lts.exe" "$B/drive_c/Enscape-setup.exe"
  w 'C:\Enscape-setup.exe' -gui=0 -auto >>"$LOGDIR/enscape-setup.log" 2>&1; local rc=$?
  rm -f "$B/drive_c/Enscape-setup.exe"
  cp "$B/drive_c/users/crossover/AppData/Local/Enscape/Logs/Enscape.Installer/"*.log "$LOGDIR/" 2>/dev/null
  [ -f "$B/drive_c/Program Files/Enscape/RendererHost/Enscape.RendererHost.exe" ] || { echo "enscape: installer exit=$rc, Enscape not installed" >&2; return 1; }
  # Its license check reads the computer's UUID through WMI with .NET's System.Management, which loads wminet_utils.dll
  # from .NET Framework 4.8; the 2027 bottle has no .NET Framework. Take the DLL and its two runtime DLLs from the
  # .NET 4.8 installer that Enscape ships (no .NET Framework install).
  local tmp; tmp="$(mktemp -d)" || return 1
  7zz e -y -o"$tmp" "$B/drive_c/Program Files/Enscape/redist/ndp48-x86-x64-allos-enu.exe" netfx_Full.mzz >/dev/null &&
    7zz e -y -o"$tmp" "$tmp/netfx_Full.mzz" wminet_utils_dll_amd64 vcruntime140_clr0400_dll_amd64 ucrtbase_clr0400_dll_amd64 >/dev/null &&
    cp "$tmp/wminet_utils_dll_amd64" "$B/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/wminet_utils.dll" &&
    cp "$tmp/vcruntime140_clr0400_dll_amd64" "$S32/vcruntime140_clr0400.dll" &&
    cp "$tmp/ucrtbase_clr0400_dll_amd64" "$S32/ucrtbase_clr0400.dll"; rc=$?
  rm -rf "$tmp"; [ $rc = 0 ] || { echo "enscape: wminet_utils.dll from .NET 4.8 failed" >&2; return 1; }
  # Vulkan fixes (tools/vkshim): Enscape turns down the Mac GPU (logicOp); its view takes keys and the mouse only when active.
  "$ROOT/scripts/build-vkshim.sh" >>"$LOGDIR/vkshim.log" 2>&1 || { echo "enscape: vkshim build failed, see $LOGDIR/vkshim.log" >&2; return 1; }
  [ -f "$S32/vulkan-1.dll.wine-fake" ] || cp "$S32/vulkan-1.dll" "$S32/vulkan-1.dll.wine-fake"
  cp "$ROOT/build/vkshim/vulkan-1.dll" "$S32/vulkan-1.dll.new" && mv -f "$S32/vulkan-1.dll.new" "$S32/vulkan-1.dll"
  w reg add "$A" /v vulkan-1 /d native,builtin /f >>"$LOGDIR/wine.log" 2>&1
  # No Direct3D 11 for Enscape's own windows (Avalonia): through D3DMetal, closing a menu deadlocks with the renderer
  # inside CrossOver's Mac driver; through any D3D the window's Metal layer hides the Asset Library browser. Without
  # d3d11 Avalonia draws in software.
  w reg add "$A" /v d3d11 /d '' /f >>"$LOGDIR/wine.log" 2>&1
  # Asset Library is a WebView2 browser: it needs the same browser arguments as Revit's (tools/rvtfix) from the start of
  # the process. Our version.dll (tools/wv2fix, updated here) loads rvtfix.dll that sits next to the exe.
  "$ROOT/scripts/install-odis.sh" 2027 "$NAME" wv2fix >>"$LOGDIR/wv2fix.log" 2>&1 || { echo "enscape: wv2fix step failed" >&2; return 1; }
  "$ROOT/scripts/build-rvtfix.sh" >>"$LOGDIR/rvtfix.log" 2>&1 || { echo "enscape: rvtfix build failed, see $LOGDIR/rvtfix.log" >&2; return 1; }
  cp "$ROOT/build/rvtfix/rvtfix.dll" "$B/drive_c/Program Files/Enscape/RendererHost/rvtfix.dll"
  w reg add "$A" /v version /d native,builtin /f >>"$LOGDIR/wine.log" 2>&1
  "$ROOT/scripts/bottle-env.sh" "$NAME" MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 >/dev/null
  # Chaos Unified Login (sign-in) and Cosmos (Asset Library) start from the Windows StartUp folder, which Wine does not
  # run. Make them auto-start services through tools/svcshim; Wine starts those with the bottle.
  "$ROOT/scripts/build-svcshim.sh" >>"$LOGDIR/svcshim.log" 2>&1 || { echo "enscape: svcshim build failed, see $LOGDIR/svcshim.log" >&2; return 1; }
  cp "$ROOT/build/svcshim/svcshim.exe" "$B/drive_c/Program Files/Chaos/svcshim.exe"
  local svc
  for svc in 'ChaosUnifiedLogin|Chaos Unified Login|"C:\Program Files\Chaos\UnifiedLogin\ulasupervisor.exe"' \
             'ChaosCosmos|Chaos Cosmos Browser|"C:\Program Files\Chaos\Cosmos\cbservice.exe" supervisor 0'; do
    IFS='|' read -r n d c <<<"$svc"; local K='HKLM\System\CurrentControlSet\Services\'"$n"
    w reg add "$K" /v Type /t REG_DWORD /d 16 /f && w reg add "$K" /v Start /t REG_DWORD /d 2 /f &&
      w reg add "$K" /v ErrorControl /t REG_DWORD /d 1 /f && w reg add "$K" /v ObjectName /d LocalSystem /f &&
      w reg add "$K" /v DisplayName /d "$d" /f &&
      w reg add "$K" /v ImagePath /t REG_EXPAND_SZ /d "\"C:\Program Files\Chaos\svcshim.exe\" $c" /f
  done >>"$LOGDIR/wine.log" 2>&1
  WINEPREFIX="$B" "$CX/bin/wineserver" -k 2>/dev/null   # services start with the bottle; also stops the installer's copies
  echo "   enscape: installer exit=$rc; wminet_utils.dll; Vulkan fixes; d3d11 off and rvtfix for Enscape.RendererHost.exe; Chaos services"
}

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
    [ -n "$LOOKUP" ] || { echo "revitlookup: not set up for $YEAR" >&2; exit 1; }
    cp "$LOOKUP" "$B/drive_c/RevitLookup.msi"
    w msiexec /i 'C:\RevitLookup.msi' /qn /l*v 'C:\d8-revitlookup.log' >>"$LOGDIR/wine.log" 2>&1; RC=$?
    rm -f "$B/drive_c/RevitLookup.msi"; mv "$B/drive_c/d8-revitlookup.log" "$LOGDIR/" 2>/dev/null
    echo "   revitlookup exit=$RC  $(( $(date +%s) - t0 ))s"
    ;;
  pyrevit)
    [ -n "$PYRSETUP" ] || { echo "pyrevit: not set up for $YEAR" >&2; exit 1; }
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
  trust)
    # "This signed add-in has been found" → "Always Load" adds the signer's certificate to the user's TrustedPublisher
    # store; under Wine that write doesn't happen, so Revit asks again on every start. Do it for the add-ins in the user
    # and all-users Addins folders (pyRevit 4.8 installs for all users; Enscape for 2027 into Program Files): the
    # assemblies their .addin manifests name (absolute, or relative to the manifest).
    files=()
    for m in "$ADDINS"/*.addin "${ALLADDINS[0]}"/*.addin "${ALLADDINS[1]}"/*.addin; do
      [ -f "$m" ] || continue
      while IFS= read -r a; do
        case "$a" in [A-Za-z]:\\*) f="$B/drive_c/$(echo "${a:3}" | tr '\\' /)";; *) f="$(dirname "$m")/$(echo "$a" | tr '\\' /)";; esac
        [ -f "$f" ] && files+=("$f")
      done < <(grep -o '<Assembly>[^<]*' "$m" | sed 's/<Assembly>//' | tr -d '\r')
    done
    if [ ${#files[@]} -eq 0 ]; then echo "   trust: no add-in assemblies in $ADDINS"
    else
      python3 -I "$ROOT/tools/trustpub.py" "$B/drive_c/d8-trust.reg" "${files[@]}" | sed "s|$B/drive_c/||; s|^|   trust: |"
      w regedit /s 'C:\d8-trust.reg' >>"$LOGDIR/wine.log" 2>&1; RC=$?
      mv "$B/drive_c/d8-trust.reg" "$LOGDIR/"; echo "   trust exit=$RC"
    fi
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
    case "$YEAR" in 2020|2027) ;; *) echo "enscape: set up and tested for Revit 2020 and 2027 only" >&2; exit 1;; esac
    if [ "$YEAR" = 2027 ]; then enscape4; RC=$?; echo "   enscape exit=$RC  $(( $(date +%s) - t0 ))s"; continue; fi
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
    # Vulkan fixes (tools/vkshim): Enscape's GPU check, its query pools and the focus of its view under Wine/MoltenVK.
    # Into system32: at Revit start DXVK (d3d9dxvk) loads vulkan-1.dll from there before Enscape does. Wine takes a
    # native DLL from system32 only where native,builtin is set, here for Revit.exe. Wine's file is kept as .wine-fake.
    "$ROOT/scripts/build-vkshim.sh" >>"$LOGDIR/vkshim.log" 2>&1 || { echo "enscape: vkshim build failed, see $LOGDIR/vkshim.log" >&2; exit 1; }
    S32="$B/drive_c/windows/system32"
    [ -f "$S32/vulkan-1.dll.wine-fake" ] || cp "$S32/vulkan-1.dll" "$S32/vulkan-1.dll.wine-fake"
    cp "$ROOT/build/vkshim/vulkan-1.dll" "$S32/vulkan-1.dll.new" && mv -f "$S32/vulkan-1.dll.new" "$S32/vulkan-1.dll"
    w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v vulkan-1 /d native,builtin /f >>"$LOGDIR/wine.log" 2>&1
    # CrossOver builds MoltenVK with Metal argument buffers off (Enscape's shaders do not compile: black geometry) and
    # with asynchronous queue submits (Enscape hangs when its window is resized). Back to MoltenVK's own defaults.
    "$ROOT/scripts/bottle-env.sh" "$NAME" MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 >/dev/null
    echo "   enscape exit=$RC; System.ValueTuple → net47 facade ($(wc -c <"$VT" | tr -d ' ') bytes); Vulkan fixes in system32\\vulkan-1.dll  $(( $(date +%s) - t0 ))s"
    ;;
  enscape-off|enscape-on)
    # Turn Enscape off without uninstalling: move the manifest to Addins\<year>.off, leave the files alone.
    AD="${ALLADDINS[0]}"; [ "$YEAR" = 2027 ] && AD="${ALLADDINS[1]}"; mkdir -p "$AD.off"
    if [ "$s" = enscape-off ]; then mv "$AD/0_Enscape.addin" "$AD.off/" 2>/dev/null; else mv "$AD.off/0_Enscape.addin" "$AD/" 2>/dev/null; fi
    echo "   $s: $(ls "$AD"/0_Enscape.addin 2>/dev/null || echo 'manifest disabled')"
    ;;
  check)
    echo ">> check: .NET Release=$(net_release)"
    ls "$ADDINS"/*.addin "${ALLADDINS[0]}"/*.addin "${ALLADDINS[1]}"/*.addin 2>/dev/null | sed "s|$B/||; s|^|   |"
    ;;
  *) echo "unknown step $s" >&2; exit 1;;
  esac
done
