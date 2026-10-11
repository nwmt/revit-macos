#!/usr/bin/env bash
# Installs Revit with the ODIS installer (2023, 2026, 2027; probably 2024–2025 too) component by component, bypassing Setup.exe.
# Order and switches come from manifest/app.RVT.xml and x64/RVT/pkg.RVT.xml (Dependencies), see versions/<year>.md.
# Usage: ./scripts/install-odis.sh <year> <bottle> [steps...]
#   default steps: vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk dpipatch richedit tlbpin warpshim gdoff rvtfix wv2fix
#   2025: the default + pdfprinter dynamo
#   2023 (sign-in through AdSSO as in 2020, no WebView2/IdentityManager/ASC packages):
#     vc fonts dotnet licensing svcshim adsso rvt pkgs register ncryptshim ssoenv wbemshim d3d9dxvk dpipatch richedit tlbpin warpshim gdoff rvtfix pdfprinter dynamo
# The installer must be extracted: ./scripts/inspect-installer.sh <year> --extract
set -uo pipefail
YEAR="${1:?specify a year}"; NAME="${2:?specify a bottle}"; shift 2
STEPS=("$@")
if [ ${#STEPS[@]} -eq 0 ]; then
  case "$YEAR" in
    2023) STEPS=(vc fonts dotnet licensing svcshim adsso rvt pkgs register ncryptshim ssoenv wbemshim d3d9dxvk dpipatch richedit tlbpin warpshim gdoff rvtfix pdfprinter dynamo) ;;
    2025) STEPS=(vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk dpipatch richedit tlbpin warpshim gdoff rvtfix wv2fix pdfprinter dynamo) ;;
    *)    STEPS=(vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk dpipatch richedit tlbpin warpshim gdoff rvtfix wv2fix) ;;
  esac
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/versions.sh"
DIST="$(revit_dist "$YEAR")"
LANG_UI="${REVIT_LANG:-en-US}"
PKGS_CORE="$(revit_pkgs_core "$YEAR")" # core set for the pkgs step (scripts/lib/versions.sh)
for s in "${STEPS[@]}"; do # only steps that install from the installer need it; workarounds (rvtfix, wv2fix, …) don't
  case "$s" in vc|dotnet|net8|licensing|idmgr|adsso|rvt|pkgs|asc|register)
    [ -f "$DIST/setup.xml" ] || { echo "no extracted installer at $DIST (step $s)" >&2; exit 1; } ;; esac
done
LOGDIR="$ROOT/logs/install-$NAME-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$LOGDIR"
. "$ROOT/scripts/lib/bottle.sh"
cd "$B/drive_c" # wine cwd = script cwd; otherwise relative MSI paths land in the current folder
echo ">> Revit $YEAR → bottle $NAME, logs: $LOGDIR"

for s in "${STEPS[@]}"; do
  case "$s" in
    vc) # VC++ 2022 (v14) — supersedes 2019, which ODIS also installs; 2019 after 2022 would return 1638
      override api-ms-win-crt-private-l1-1-0 api-ms-win-crt-conio-l1-1-0 api-ms-win-crt-heap-l1-1-0 \
        api-ms-win-crt-locale-l1-1-0 api-ms-win-crt-math-l1-1-0 api-ms-win-crt-runtime-l1-1-0 \
        api-ms-win-crt-stdio-l1-1-0 api-ms-win-crt-time-l1-1-0 atl140 concrt140 msvcp140 msvcp140_1 \
        msvcp140_2 msvcp140_atomic_wait ucrtbase vcamp140 vcomp140 vccorlib140 vcruntime140 vcruntime140_1
      if [ -d "$DIST/3rdParty/x64/VCRedist/2022" ]; then
        run_exe vc22x86 "$DIST/3rdParty/x86/VCRedist/2022/VC_redist.x86.exe" /install /quiet /norestart
        run_exe vc22x64 "$DIST/3rdParty/x64/VCRedist/2022/VC_redist.x64.exe" /install /quiet /norestart
      else # 2023: 2012, 2013, (2017 x86), 2019 — every one the installer ships, oldest first, switches from its pkg.*.xml
        for x in "$DIST"/3rdParty/x86/VCRedist/*/pkg.*.xml "$DIST"/3rdParty/x64/VCRedist/*/pkg.*.xml; do
          f="$(grep -o 'file="[^"]*"' "$x" | head -1 | cut -d'"' -f2)"; p="$(grep -o 'installParams="[^"]*"' "$x" | head -1 | cut -d'"' -f2)"
          read -r -a args <<< "${p%% /l *}" # drop "/l %temp%\…log": %temp% is not expanded here
          v="$(basename "$(dirname "$x")")"; arch="${x#"$DIST"/3rdParty/}"; arch="${arch%%/*}"
          run_exe "vc${v:2:2}$arch" "$DIST/$f" "${args[@]}"
        done
      fi ;;
    fonts) # corefonts + msxml6 (like d2 for 2020)
      WINE="$ROOT/scripts/lib/cxwine" WINESERVER="$CX/bin/wineserver" CX_BOTTLE="$NAME" WINEPREFIX="$B" \
        winetricks -q --unattended corefonts msxml6 >>"$LOGDIR/winetricks.log" 2>&1
      say fonts "$?" "winetricks corefonts msxml6" ;;
    dotnet|net8) # .NET Desktop + ASP.NET Core from the installer (2026: 8.0, folders 80; 2027: 10.0, folders 100; switches from pkg.dotnet*.xml / pkg.aspnet*.xml)
      if [ "$(revit_dotnet "$YEAR")" = netfx48 ]; then # 2021–2024: .NET Framework 4.8 from the installer on top of real 4.0 (as 4.7 for 2020)
        "$ROOT/scripts/d3-dotnet47.sh" "$NAME" "$DIST/3rdParty/dotNetFramework/48/dotNetFx48_Full_x86_x64.exe" >>"$LOGDIR/netfx48.log" 2>&1
        w wineboot -r >>"$LOGDIR/wine.log" 2>&1 # the MSI asks for a reboot (pending file renames)
        rel="$(w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>/dev/null | tr -d '\r' | awk '/Release/{print $3}')"
        say netfx48 "$([ $((rel)) -ge 528040 ] && echo 0 || echo 1)" "Release=$((rel)) (528040+ = 4.8)"; continue
      fi
      # every runtime the installer ships: an update laid over the base (inspect-installer.sh) adds a newer one (2026.5: 10.0 next to 8.0)
      for x in $(ls "$DIST"/3rdParty/x64/dotNet/*/windowsdesktop-runtime-*.exe | sort -V); do run_exe "netdesk$(basename "$(dirname "$x")")" "$x" /install /quiet /norestart; done
      for x in $(ls "$DIST"/3rdParty/x64/aspNetCore/*/aspnetcore-runtime-*.exe | sort -V); do run_exe "netasp$(basename "$(dirname "$x")")" "$x" /q /norestart; done
      ls "$B/drive_c/Program Files/dotnet/shared/"*/ 2>/dev/null | sed 's/^/   /' | tee -a "$LOGDIR/summary.txt" ;;
    licensing) # BitRock InstallBuilder, switches from pkg.licensing.xml
      AL="$B/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
      # re-running over our Current symlink fails (LIC-INST-ERROR-240) — install only once
      if [ -L "$AL/Current" ]; then say licensing skip "already installed: $(readlink "$AL/Current")"
      else
        run_exe licensing "$DIST/x86/Licensing/AdskLicensing-installer.exe" --mode unattended --unattendedmodeui none
        cp "$B"/drive_c/users/crossover/AppData/Local/Temp/AdskLicensing-install.log "$LOGDIR/" 2>/dev/null
      fi
      # as in 2020: mklink /J under Wine creates an empty "Current<garbage>" folder instead of a junction → symlink
      for f in "$AL"/Current?*; do [ -d "$f" ] && [ ! -L "$f" ] && rmdir "$f" 2>/dev/null; done
      ver="$(ls "$AL" 2>/dev/null | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1)"
      if [ -n "$ver" ] && [ ! -e "$AL/Current" ]; then ln -sfn "$ver" "$AL/Current"; say licensing 0 "Current -> $ver (mklink fix)"; fi
      # the installer writes version.ini after `servicectl start`, which fails under Wine (1053) → no file,
      # and the licMarkInstall custom action in RVT.msi fails the install (1603). Write it ourselves, as for 2020.
      if [ -n "$ver" ] && [ ! -f "$AL/version.ini" ]; then
        printf '[General]\r\nversion=%s\r\n' "$ver" > "$AL/version.ini"; say licensing 0 "version.ini ← $ver (installer did not get that far)"
      fi
      w sc query AdskLicensingService 2>/dev/null | tr -d '\r' | grep -E 'STATE' | sed 's/^/   AdskLicensingService /' | tee -a "$LOGDIR/summary.txt" ;;
    svcshim) # the licensing service (Go) doesn't answer SCM under Wine (1053) — native shim tools/svcshim
      AL='C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing'
      [ -f "$ROOT/build/svcshim/svcshim.exe" ] || "$ROOT/scripts/build-svcshim.sh" >>"$LOGDIR/svcshim.log" 2>&1
      cp "$ROOT/build/svcshim/svcshim.exe" "$B/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing/svcshim.exe"
      mkdir -p "$B/drive_c/ProgramData/Autodesk/AdskLicensingService/Log"
      # sc config binPath= doesn't change the path under Wine → ImagePath in the registry; SCM rereads it after a wineserver restart
      w reg add 'HKLM\System\CurrentControlSet\Services\AdskLicensingService' /v ImagePath /t REG_EXPAND_SZ \
        /d "\"$AL\\svcshim.exe\"" /f >>"$LOGDIR/svcshim.log" 2>&1
      WINEPREFIX="$B" "$CX/bin/wineserver" -k 2>/dev/null
      "$CX/bin/wine" --bottle "$NAME" sc start AdskLicensingService >>"$LOGDIR/svcshim.log" 2>&1 & # the service never exits
      for i in $(seq 1 20); do
        st="$("$CX/bin/wine" --bottle "$NAME" sc query AdskLicensingService 2>/dev/null | tr -d '\r' | awk '/STATE/{print $4}')"
        [ "$st" = RUNNING ] && break; sleep 2
      done
      say svcshim "${st:-?}" "AdskLicensingService → $AL\\svcshim.exe" ;;
    adsso) # 2023: Autodesk sign-in is AdSSO (QtWebEngine), as in 2020; from pkg.adsso.xml
      msi_win adsso "$(win "$DIST")\\x64\\AdSSO\\AdSSO.msi" ;;
    ssoenv) # AdSSO sign-in window (QtWebEngine): loads forever under Wine with GPU rendering, works without it (as in 2020)
      "$ROOT/scripts/bottle-env.sh" "$NAME" 'QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu --disable-gpu-compositing' \
        | sed 's/^/   ssoenv     /' | tee -a "$LOGDIR/summary.txt" ;;
    wbemshim) # WMI shim: several async queries on one IWbemServices (tools/wbem-shim), as in 2020.
              # Affects all 64-bit processes in the bottle (changes the CLSID_WbemLocator registration).
      [ -f "$ROOT/build/wbem-shim/wbemshim.dll" ] || "$ROOT/scripts/build-wbem-shim.sh" >>"$LOGDIR/wbemshim.log" 2>&1
      cp "$ROOT/build/wbem-shim/wbemshim.dll" "$B/drive_c/windows/system32/wbem/wbemshim.dll"
      w reg add 'HKLM\Software\Classes\CLSID\{4590F811-1D3A-11D0-891F-00AA004B2E24}\InprocServer32' /ve \
        /d 'C:\windows\system32\wbem\wbemshim.dll' /f >>"$LOGDIR/wbemshim.log" 2>&1
      say wbemshim "$?" "CLSID_WbemLocator (x64) -> system32\\wbem\\wbemshim.dll" ;;
    idmgr) # AdskIdentityManager (Autodesk sign-in in 2026+; 2023 uses AdSSO), switches from pkg.identity_manager.xml
      run_exe idmgr "$DIST/x64/AdskIdentityManager/AdskIdentityManager-Installer.exe" --mode unattended
      ls "$B/drive_c/Program Files/Autodesk/" 2>/dev/null | sed 's/^/   Program Files\\Autodesk\\/' | tee -a "$LOGDIR/summary.txt" ;;
    rvt) # RVT.msi: LaunchCondition "Installed or ADSK_SETUP_EXE or ADSK_ODIS_SETUP"; properties from pkg.RVT.xml.
         # RVT-wine.msi (scripts/patch-rvt-msi.sh): licIsSvcUpgraded always exits 100 under Wine → CLM_SKIP_SVCCHECK=1.
         # licRegister calls `InstHelper register --upgrade`, which in AdskLicensing 15 looks for FNP_Act_Installer.dll,
         # which no longer exists (exit 100 → 1603) → CLM_SKIP_REGISTER=1, register in the register step.
         # REVITLANGUAGE is a three-letter code (RVT.msi Property: ENU); hypothesis: Revit.ini [Language] Select comes from it. With en-US
         # Revit 2027 couldn't find template paths (revitini step). A fresh install with ENU is not yet verified.
      [ -f "$DIST/x64/RVT/RVT-wine.msi" ] || "$ROOT/scripts/patch-rvt-msi.sh" "$NAME" "$YEAR" >>"$LOGDIR/patch.log" 2>&1
      msi_win rvt "$(win "$DIST")\\x64\\RVT\\RVT-wine.msi" "TRANSFORMS=:$LANG_UI.mst;:all.mst" \
        ADSK_SETUP_EXE=1 ADSK_EULA_STATUS=#1 "ADLM_PRODKEY=$(revit_prodkey "$YEAR")" ADLM_EULA_COUNTRY=US \
        REVITLANGUAGE=ENU CLM_SKIP_SVCCHECK=1 CLM_SKIP_REGISTER=1 "INSTALLDIR=C:\\Program Files\\Autodesk\\Revit $YEAR"
      ls "$B/drive_c/Program Files/Autodesk/Revit $YEAR/Revit.exe" >/dev/null 2>&1 && say rvt 0 "Revit.exe is in place" ;;
    pkgs) # product packages from manifest/app.RVT.xml (except RVT — rvt step): ADIX via tools/adix.py, MSI via msiexec.
          # List from ODIS_PKGS (names separated by |); default is the core without Dynamo, Twinmotion, other languages. Generative Design is needed:
          # its stub .addin ships in RCPRVT; without the MSI — "GenerativeDesignForRevitApplication does not inherit from IExternalApplication".
      IFS='|' read -r -a names <<< "${ODIS_PKGS:-$PKGS_CORE}"
      python3 -I "$ROOT/tools/odis.py" get "$DIST" "${names[@]}" > "$LOGDIR/pkgs.tsv" || exit 1
      # tab is whitespace to `read` and empty columns would collapse; split on \037 instead
      while IFS=$'\037' read -r pname _as ptype pfile pparams; do
        tag="$(echo "$pname" | tr -c 'A-Za-z0-9_\n' '_')"; t0=$SECONDS
        case "$ptype" in
          ADIX)
            n="$(python3 -I "$ROOT/tools/adix.py" files "$DIST/$pfile" "$B/drive_c" 2>>"$LOGDIR/adix.log")"; rc=$?
            python3 -I "$ROOT/tools/adix.py" reg "$DIST/$pfile" "$B/drive_c/$tag.reg" >>"$LOGDIR/adix.log" 2>&1
            if [ -f "$B/drive_c/$tag.reg" ]; then
              w regedit /s "C:\\$tag.reg" >>"$LOGDIR/wine.log" 2>&1 || rc=$?
              mv "$B/drive_c/$tag.reg" "$LOGDIR/"
            fi
            say "$tag" "$rc" "ADIX $pfile: ${n:-?} files$([ -f "$LOGDIR/$tag.reg" ] && echo ' + registry') ($((SECONDS - t0)) s)" ;;
          MSI)
            read -r -a extra <<< "$pparams"
            msi_win "$tag" "$(win "$DIST/$pfile")" ADSK_SETUP_EXE=1 ${extra[@]+"${extra[@]}"}
            # Steel Connections (2025–2027): its DIRCA_INSTALLDIR builds the folder from REVIT-05\InstallRoot (which RVT.msi
            # sets to Revit's own folder here) + "Revit <year>" → "…\Revit 2025Revit 2025\", and passing INSTALLDIR doesn't
            # override it. Its language resources belong in Revit's AddIns\SteelConnections (the add-in itself is ADIX): move them.
            RD="$B/drive_c/Program Files/Autodesk/Revit $YEAR"
            if [ "$pname" = RVTCPSTLCON ] && [ -d "${RD}Revit $YEAR" ]; then
              ditto "${RD}Revit $YEAR" "$RD" && rm -rf "${RD}Revit $YEAR"
              say "$tag" "$?" "moved its files from \"Revit ${YEAR}Revit $YEAR\" into \"Revit $YEAR\""
            fi ;;
          *) say "$tag" skip "type $ptype ($pfile) — not supported" ;;
        esac
      done < <(tr '\t' '\037' < "$LOGDIR/pkgs.tsv") ;;
    asc) # Autodesk Shared Components (pkg ASC, type EXE): an ODIS bundle itself — 7z subpackages into one folder
         # %COMMONPROGRAMFILES%\Autodesk Shared\Components\<year>\<version> + ASCRegistryTool --registry set (postInstall).
         # Without it Revit 2026 fails at startup: "Autodesk Shared Components bundle is missing" (ASC status 6).
      python3 -I "$ROOT/tools/odis.py" list "$DIST" | cut -f1 | grep -qx ASC || { say asc skip "no ASC package (2025)"; continue; }
      AE="$DIST/$(python3 -I "$ROOT/tools/odis.py" get "$DIST" ASC | cut -f4)"; AX="$(dirname "$AE")/x" # 2026: x64/ASC, 2027: x64/ASC2
      [ -f "$AX/setup.xml" ] || 7zz x -y -o"$AX" "$AE" >>"$LOGDIR/asc.log" 2>&1
      ver="$(grep -oE '<BuildNumber[^>]*>[0-9.]+' "$AX/setup.xml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      base="Program Files/Common Files/Autodesk Shared/Components/$YEAR"; mkdir -p "$B/drive_c/$base/$ver"
      n=0; for z in "$AX"/*/*.7z; do 7zz x -y -o"$B/drive_c/$base/$ver" "$z" >>"$LOGDIR/asc.log" 2>&1 || say asc "$?" "$z"; n=$((n+1)); done
      say asc 0 "$n subpackages → C:\\${base//\//\\}\\$ver"
      bw="C:\\${base//\//\\}"
      tool=ASCRegistryTool.exe; [ -f "$B/drive_c/$base/$ver/$tool" ] || tool=CompRegistryTool.exe # ASC 2.0 (2027) — new name
      w "$bw\\$ver\\$tool" --installpath "$bw" --version "$ver" --releaseyear "$YEAR" --registry set >>"$LOGDIR/asc.log" 2>&1
      say ascreg "$?" "$tool --registry set"
      w reg query "HKLM\\SOFTWARE\\Autodesk\\SharedComponents\\$YEAR" 2>/dev/null | tr -d '\r' | grep -v '^$' | sed 's/^/   /' ;;
    ncryptshim) # Wine's ncrypt can't import a private ECDSA P-256 key (ECCPRIVATEBLOB) → assert in PersistenceDB\DataIntegrity.cpp:52
                # and "unrecoverable error" at startup — as in 2020. Our own ncrypt.dll (tools/ncrypt-shim) for Revit.exe only.
      [ -f "$ROOT/build/ncrypt-shim/ncrypt.dll" ] || "$ROOT/scripts/build-ncrypt-shim.sh" >>"$LOGDIR/ncryptshim.log" 2>&1
      cp "$ROOT/build/ncrypt-shim/ncrypt.dll" "$B/drive_c/Program Files/Autodesk/Revit $YEAR/ncrypt.dll"
      w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v ncrypt /d native,builtin /f >>"$LOGDIR/ncryptshim.log" 2>&1
      say ncryptshim "$?" "Revit $YEAR\\ncrypt.dll + AppDefaults\\Revit.exe ncrypt=native,builtin" ;;
    webview2) # the Autodesk sign-in window (IDSDK) in 2026 uses Edge WebView2; without it "Web browser runtime could not be initialized"
               # (IDSDK 3070: WebView2 is not found). Installer from the distribution, switches from pkg.webview2.xml.
      # The 2026 installer ships runtime 103 (2022), but Revit's SDK is 1.0.2478.35 (needs runtime ~124+): Revit gets
      # E_NOINTERFACE and closes the browser → blank start screen and Manage Links. On Windows WebView2 self-updates;
      # here we use a fresh Microsoft Evergreen Standalone from installers/redist/webview2 (see installers/README.md), if present.
      WV="$ROOT/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
      [ -f "$WV" ] || WV="$DIST/3rdParty/x64/WebView2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
      run_exe webview2 "$WV" /silent /install
      ls -d "$B/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/"*/ 2>/dev/null | sed 's/^/   /' | tee -a "$LOGDIR/summary.txt" ;;
    d3d9dxvk) # D3D9 (WPF panels, e.g. Model Browser 2026; OGS DX9) under wined3d → GL_INVALID_FRAMEBUFFER_OPERATION
              # and a crash (0xe0434352) after creating a project. As in 2020: DXVK d3d9.dll for Revit.exe.
              # WPF loads d3d9 by its full system32 path → put it there too (Wine's stub goes to .wine-fake);
              # overwrite the "Wine builtin DLL" marker in the copy, otherwise the loader swaps in the builtin d3d9.
      DX="$LOGDIR/d3d9-dxvk-native.dll"
      python3 -I -c 'import sys; d=bytearray(open(sys.argv[1],"rb").read()); i=d.find(b"Wine builtin DLL"); assert 0<i<0x100, i; d[i:i+16]=b"DXVK native  DLL"; open(sys.argv[2],"wb").write(d)' \
        "$CX/lib/dxvk/x86_64-windows/d3d9.dll" "$DX"
      cp "$DX" "$B/drive_c/Program Files/Autodesk/Revit $YEAR/d3d9.dll"
      S32="$B/drive_c/windows/system32/d3d9.dll"
      if ! LC_ALL=C grep -q -a -i dxvk "$S32" 2>/dev/null; then cp "$S32" "$S32.wine-fake"; fi
      cp "$DX" "$S32"
      w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v d3d9 /d native,builtin /f >>"$LOGDIR/d3d9dxvk.log" 2>&1
      say d3d9dxvk "$?" "DXVK d3d9.dll → Revit $YEAR + system32 (AppDefaults Revit.exe d3d9=native,builtin)" ;;
    dpipatch) # DesktopMFC.dll imports USER32!SetDialogControlDpiChangeBehavior (Win10 1703+), missing in CrossOver 26.3 Wine →
              # the loader inserts a stub; opening a view raises EXCEPTION_WINE_STUB (Revit journal: captureTryCrash 0x80000100),
              # the project closes, Revit crashes (0xe0434352). Rename the import to USER32!IsWindow: same registers,
              # no side effects, TRUE for a live window. Original kept as DesktopMFC.dll.orig.
      RD="$B/drive_c/Program Files/Autodesk/Revit $YEAR"
      if [ ! -f "$RD/DesktopMFC.dll.orig" ] && ! LC_ALL=C grep -q -a SetDialogControlDpiChangeBehavior "$RD/DesktopMFC.dll"; then
        say dpipatch skip "DesktopMFC.dll does not import SetDialogControlDpiChangeBehavior"; continue; fi
      [ -f "$RD/DesktopMFC.dll.orig" ] || cp "$RD/DesktopMFC.dll" "$RD/DesktopMFC.dll.orig"
      python3 -I - "$RD/DesktopMFC.dll.orig" "$RD/DesktopMFC.dll" >>"$LOGDIR/dpipatch.log" 2>&1 <<'PY2'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
old = b"SetDialogControlDpiChangeBehavior\0"; new = b"IsWindow\0".ljust(len(old), b"\0")
n = d.count(old); assert n == 1, f"expected 1 occurrence, found {n}"
i = d.find(old); d[i:i+len(old)] = new
open(sys.argv[2], "wb").write(d); print("patched at", hex(i))
PY2
      say dpipatch "$?" "DesktopMFC.dll: import SetDialogControlDpiChangeBehavior -> IsWindow" ;;
    richedit) # native x64 RichEdit (Win7 SP1) for Revit.exe only: TOM in Wine's RichEdit is stubs → text in views crashes.
              # 2026: TextEngine loads MsftEdit.dll (2020 used riched20); Revit journal: "Failed to set default tab size"
              # (RichTextFormattingUtils.cpp) → captureTryCrash 0xc0000005 in generateViewSpecificGRep when creating a project.
              # msftedit/riched20 delay-load msls31 and usp10; x64 msls31 comes from any Windows 7/10 x64 install (installers/README.md).
      RX="$ROOT/installers/redist/win7sp1/x64"
      [ -f "$RX/riched20.dll" ] || "$ROOT/scripts/get-win7-richedit.sh" >>"$LOGDIR/richedit.log" 2>&1
      [ -f "$RX/msls31.dll" ] || { echo "no $RX/msls31.dll (x64, copy from any Windows 7/10 x64 install)" >&2; exit 1; }
      # msftedit goes only to system32: Revit looks in its own folder first, but the system32 copy is already loaded by then;
      # a second copy fails to register window classes, DllMain → FALSE, "Revit could not load …\MsftEdit.dll".
      rm -f "$B/drive_c/Program Files/Autodesk/Revit $YEAR/msftedit.dll"
      for dll in msftedit riched20 usp10 msls31; do
        [ "$dll" = msftedit ] || cp "$RX/$dll.dll" "$B/drive_c/Program Files/Autodesk/Revit $YEAR/$dll.dll"
        # loaded by full system32 path → put them there too; Wine's builtin stub goes to .wine-fake
        S32="$B/drive_c/windows/system32/$dll.dll"
        if LC_ALL=C grep -q -a 'Wine builtin DLL' "$S32" 2>/dev/null; then cp "$S32" "$S32.wine-fake"; fi
        cp "$RX/$dll.dll" "$S32"
        w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v "$dll" /d native,builtin /f >>"$LOGDIR/richedit.log" 2>&1
      done
      say richedit "$?" "msftedit (system32), riched20 usp10 msls31 → Revit $YEAR + system32 (AppDefaults Revit.exe native,builtin)" ;;
    tlbpin) # LoadRegTypeLib(LIBID_tom) cache for Revit.exe (tools/tlbpin as msls31.dll → msls31_ms.dll): otherwise the TOM typelib
            # is re-parsed for every text — views are created 2–3x slower (measured on 2020). Run after richedit.
      "$ROOT/scripts/build-tlbpin.sh" >>"$LOGDIR/tlbpin.log" 2>&1
      RX="$ROOT/installers/redist/win7sp1/x64"
      for d in "$B/drive_c/windows/system32" "$B/drive_c/Program Files/Autodesk/Revit $YEAR"; do
        cp "$RX/msls31.dll" "$d/msls31_ms.dll"; cp "$ROOT/build/tlbpin/msls31.dll" "$d/msls31.dll"
      done
      w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v msls31_ms /d native,builtin /f >>"$LOGDIR/tlbpin.log" 2>&1
      say tlbpin "$?" "msls31.dll (shim + TOM cache) → msls31_ms.dll" ;;
    warpshim) # the material browser requires D3D11 WARP, which D3DMetal lacks → "Can't get OGS device … Material Browser dialog
              # can't be created", the window doesn't open (as in 2020). d3dwp.dll (tools/d3d11-warp-shim): WARP → HARDWARE;
              # in OGSDeviceDX11.dll L"D3D11.dll" → L"d3dwp.dll" (same length). Original kept as OGSDeviceDX11.dll.orig.
      RD="$B/drive_c/Program Files/Autodesk/Revit $YEAR"
      [ -f "$ROOT/build/d3dwp/d3dwp.dll" ] || "$ROOT/scripts/build-d3dwp.sh" >>"$LOGDIR/warpshim.log" 2>&1
      cp "$ROOT/build/d3dwp/d3dwp.dll" "$RD/d3dwp.dll"
      [ -f "$RD/OGSDeviceDX11.dll.orig" ] || cp "$RD/OGSDeviceDX11.dll" "$RD/OGSDeviceDX11.dll.orig"
      python3 -I - "$RD/OGSDeviceDX11.dll.orig" "$RD/OGSDeviceDX11.dll" >>"$LOGDIR/warpshim.log" 2>&1 <<'PY2'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
old, new = "D3D11.dll\0".encode("utf-16le"), "d3dwp.dll\0".encode("utf-16le")
n = d.count(old); assert n == 1, f"expected 1 occurrence of L'D3D11.dll', found {n}"
i = d.find(old); d[i:i+len(old)] = new
open(sys.argv[2], "wb").write(d); print("patched at", hex(i))
PY2
      say warpshim "$?" "d3dwp.dll + OGSDeviceDX11.dll: L\"D3D11.dll\" -> L\"d3dwp.dll\"" ;;
    wv2env) # HYPOTHESIS: Revit's embedded WebView2 (start screen, Manage Links) shows a blank window, msedgewebview2 processes
            # quietly exit without crashing. Like Qt WebEngine in 2020 (ssoenv) — no GPU compositing. For all processes in the bottle.
      "$ROOT/scripts/bottle-env.sh" "$NAME" 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu --disable-gpu-compositing' \
        | sed 's/^/   wv2env     /' | tee -a "$LOGDIR/summary.txt" ;;
    gdoff) # Generative Design: "GenerativeDesignForRevitApplication does not inherit from IExternalApplication" even with the MSI.
           # Interactively it's a dismissable dialog; during journal playback (RFO benchmark) — "unrecoverable error" at startup.
           # Disable the add-in (reversible: .addin.off). Root cause not investigated (hypothesis: needs Dynamo).
      A="$B/drive_c/Program Files/Autodesk/Revit $YEAR/AddIns/GenerativeDesignForRevit/GenerativeDesignForRevit.addin"
      [ -f "$A" ] || [ -f "$A.off" ] || { say gdoff skip "no Generative Design add-in (2027)"; continue; }
      [ -f "$A" ] && mv "$A" "$A.off"
      say gdoff "$([ -f "$A.off" ] && echo 0 || echo 1)" "GenerativeDesignForRevit.addin → .addin.off" ;;
    rvtfix) # Wine fixes inside the Revit process (tools/rvtfix, loaded by our ncrypt.dll — run after ncryptshim).
            # Currently: RegisterDragDrop/RevokeDragDrop on another process's window (start screen: the WebView2 window) —
            # Wine's ole32 crashes with AccessViolation, Windows returns DRAGDROP_E_INVALIDHWND. Patching the ole32 name in the
            # ModelBrowser assembly isn't possible: Revit verifies add-in signatures ("Verify failed!") and won't load it.
            # 2023: adds --in-process-gpu for the CefSharp start screen, which stays blank otherwise.
      "$ROOT/scripts/build-ncrypt-shim.sh" >>"$LOGDIR/rvtfix.log" 2>&1; "$ROOT/scripts/build-rvtfix.sh" >>"$LOGDIR/rvtfix.log" 2>&1
      cp "$ROOT/build/ncrypt-shim/ncrypt.dll" "$ROOT/build/rvtfix/rvtfix.dll" "$B/drive_c/Program Files/Autodesk/Revit $YEAR/"
      say rvtfix "$?" "rvtfix.dll + ncrypt.dll (loads rvtfix) → Revit $YEAR" ;;
    wv2fix) # the WebView2 browser crashes inside Revit: "err:system:user_check_not_lock BUG: holding USER lock" when WS_VISIBLE
            # is restored on a window nested in a Revit window (Chromium redraw lock; CrossOver 26.3) → start screen "reloads", empty
            # Project Browser in 2027. tools/wv2fix is our own version.dll (imported by msedge.dll) that skips that toggle.
            # The browser's main process loads system DLLs only from system32 → put it there (Wine's builtin stub goes
            # to .wine-fake); native,builtin override only for msedgewebview2.exe, everyone else gets the builtin version.dll.
            # version_orig.dll is Wine's builtin version.dll without the builtin marker (otherwise the loader swaps it).
      "$ROOT/scripts/build-wv2fix.sh" >>"$LOGDIR/wv2fix.log" 2>&1
      S32="$B/drive_c/windows/system32"
      if LC_ALL=C grep -q -a 'Wine builtin DLL' "$S32/version.dll" 2>/dev/null; then cp "$S32/version.dll" "$S32/version.dll.wine-fake"; fi
      python3 -I -c 'import sys; d=bytearray(open(sys.argv[1],"rb").read()); i=d.find(b"Wine builtin DLL"); assert 0<i<0x100, i; d[i:i+16]=b"Wine orig    DLL"; open(sys.argv[2],"wb").write(d)' \
        "$CX/lib/wine/x86_64-windows/version.dll" "$S32/version_orig.dll.new" && mv -f "$S32/version_orig.dll.new" "$S32/version_orig.dll" &&
        cp "$ROOT/build/wv2fix/version.dll" "$S32/version.dll.new" && mv -f "$S32/version.dll.new" "$S32/version.dll" # new inode: a running browser keeps the old file
      rm -f "$B/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/"[0-9]*/version*.dll # previous variant (runtime folder)
      w reg add 'HKCU\Software\Wine\AppDefaults\msedgewebview2.exe\DllOverrides' /v version /d native,builtin /f >>"$LOGDIR/wv2fix.log" 2>&1
      say wv2fix "$?" "version.dll (+version_orig.dll) → system32; AppDefaults msedgewebview2.exe version=native,builtin" ;;
    pdfprinter) # "Revit PDF" printer, as in 2020: Wine PostScript driver + tools/pdf-printer/revitpdf.ppd (A4…A0, ARCH),
                # port REVITPDF: → |scripts/ps2pdf-port.sh (Ghostscript → ~/Documents/Revit-PDF). The Mac has no CUPS queues,
                # and without a printer Revit won't open Print/Page Setup.
      "$ROOT/scripts/build-add-printer.sh" >>"$LOGDIR/pdfprinter.log" 2>&1
      mkdir -p "$B/drive_c/rvt-pdf" "$B/drive_c/windows/system32/spool/drivers/x64/3"
      cp "$ROOT/build/pdf-printer/add_printer.exe" "$ROOT/tools/pdf-printer/revitpdf.ppd" "$B/drive_c/rvt-pdf/"
      # Wine's AddPrinterDriverEx copies only wineps.drv, and wineps looks for the PPD in the driver directory — copy it ourselves.
      cp "$ROOT/tools/pdf-printer/revitpdf.ppd" "$B/drive_c/windows/system32/spool/drivers/x64/3/revitpdf.ppd"
      command -v gs >/dev/null || [ -x /opt/homebrew/bin/gs ] || echo "   warning: no Ghostscript (brew install ghostscript) — you will get .ps instead of .pdf" >&2
      {
        w reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Ports' /v 'REVITPDF:' /t REG_SZ /d '' /f
        w reg add 'HKCU\Software\Wine\Printing\Spooler' /v 'REVITPDF:' /t REG_SZ /d "|$ROOT/scripts/ps2pdf-port.sh" /f
        w regsvr32 /s wineps.drv
        w 'C:\rvt-pdf\add_printer.exe' 'Revit PDF' 'C:\rvt-pdf\revitpdf.ppd' 'REVITPDF:'
      } >>"$LOGDIR/pdfprinter.log" 2>&1
      say pdfprinter "$?" "Revit PDF → REVITPDF: → scripts/ps2pdf-port.sh" ;;
    dynamo) # Dynamo's 3D preview (HelixToolkit.SharpDX) breaks under D3DMetal: crash in 2020 (GetSharedHandle → E_NOTIMPL),
            # black squares and lag across Revit in 2023. As in 2020: turn off Dynamo's hardware acceleration and background
            # 3D preview, keep the preview in Revit views. Dynamo writes the file on exit: run with Revit closed.
      DV="$(revit_dynamo "$YEAR")" || { say dynamo skip "no Dynamo version for $YEAR"; continue; }
      DS="$B/drive_c/users/crossover/AppData/Roaming/Dynamo/Dynamo Revit/$DV/DynamoSettings.xml"
      mkdir -p "$(dirname "$DS")"
      python3 -I - "$DS" >>"$LOGDIR/dynamo.log" 2>&1 <<'PY'
import os, sys, xml.etree.ElementTree as ET
p = sys.argv[1]
if os.path.exists(p):
    t = ET.parse(p); r = t.getroot()
else:
    r = ET.Element("PreferenceSettings"); t = ET.ElementTree(r)
    ET.SubElement(r, "IsFirstRun").text = "false"
def setv(tag, val):
    e = r.find(tag)
    if e is None: e = ET.SubElement(r, tag)
    e.text = val
setv("UseHardwareAcceleration", "false")
bp = r.find("BackgroundPreviews")
if bp is None: bp = ET.SubElement(r, "BackgroundPreviews")
st = {e.findtext("Name"): e for e in bp.findall("BackgroundPreviewActiveState")}
for name, val in (("IsBackgroundPreviewActive", "false"), ("IsRevitBackgroundPreviewActive", "true")):
    e = st.get(name)
    if e is None:
        e = ET.SubElement(bp, "BackgroundPreviewActiveState"); ET.SubElement(e, "Name").text = name; ET.SubElement(e, "IsActive")
    e.find("IsActive").text = val
t.write(p, xml_declaration=True, encoding="utf-8")
print("ok", p)
PY
      say dynamo "$?" "Dynamo $DV DynamoSettings.xml: UseHardwareAcceleration=false, IsBackgroundPreviewActive=false" ;;
    revitini) # Revit takes template and library paths from [Directories<Select>] in Revit.ini. After installing 2027
              # [Language] Select=en-US (2026 has ENU) → there's no [Directoriesen-US] section → "The path specified for default
              # family templates is empty or invalid", empty template and library lists. Set Select=ENU.
              # Defaults for new users (2025+, values as Revit writes them after changing Options by hand):
              #   [Graphics] Antialiasing=0 AntialiasingOptions=1 — anti-aliasing off: smoother under Wine, and DXMT draws
              #   a black view with it; [AppFrame] Theme, [Colors] CanvasTheme — 0 dark, 1 light (Revit API UITheme/CanvasTheme),
              #   from the macOS appearance at install time, or REVIT_THEME=dark|light.
              # 2025: Revit finds RealDWG Shared (DWG import/export, needed at startup) through the HIVE host, which asks ODIS's
              #   install database; we install packages without ODIS, so Revit says "Cannot load the required component Autodesk
              #   RealDWG Shared" and exits. Revit first takes the path it cached in [Interoperability] → give it the path.
              # Revit.ini lives in ProgramData (seed for new users) and in the user profile; Revit must be closed.
      keys=(Language.Select=ENU)
      [ "$YEAR" = 2025 ] && keys+=("Interoperability.RealDWGInstalledLocation=C:\\Program Files\\Autodesk\\RealDWG Shared $YEAR\\")
      if [ "$YEAR" -ge 2025 ]; then
        theme="${REVIT_THEME:-$(defaults read -g AppleInterfaceStyle 2>/dev/null | grep -qi dark && echo dark || echo light)}"
        t=1; [ "$theme" = dark ] && t=0; theme+=", from ${REVIT_THEME:+REVIT_THEME}"; [ -n "${REVIT_THEME:-}" ] || theme+="macOS"
        keys+=(Graphics.Antialiasing=0 Graphics.AntialiasingOptions=1 AppFrame.Theme=$t AppFrame.FollowSystemColorTheme=0 Colors.CanvasTheme=$t)
      fi
      for f in "$B/drive_c/ProgramData/Autodesk/RVT $YEAR/UserDataCache/Revit.ini" \
               "$B/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit $YEAR/Revit.ini"; do
        [ -f "$f" ] || continue; [ -f "$f.orig" ] || cp "$f" "$f.orig" # from .orig — re-running gives the same result
        python3 -I "$ROOT/tools/revitini.py" "$f.orig" "$f" "${keys[@]}" >>"$LOGDIR/revitini.log" 2>&1
        say revitini "$?" "Revit.ini ${keys[*]}${theme:+ ($theme)}: ${f#$B/drive_c/}"
      done ;;
    register) # register the product with AdskLicensing (instead of licRegister in the MSI), like the 2020 register step
      PIT="C:\\ProgramData\\Autodesk\\Revit\\Revit $YEAR\\Setup\\RevitConfig.pit"
      mkdir -p "$B/drive_c/ProgramData/Autodesk/Revit/Revit $YEAR/Setup"
      cp "$DIST/x64/RVT/RevitConfig.pit" "$B/drive_c/ProgramData/Autodesk/Revit/Revit $YEAR/Setup/"
      H='C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\helper\AdskLicensingInstHelper.exe'
      w "$H" register --pk "$(revit_prodkey "$YEAR")" --pv "$YEAR.0.0.F" --el US --lm USER --cf "$PIT" >>"$LOGDIR/register.log" 2>&1
      say register "$?" "$(revit_prodkey "$YEAR") $YEAR.0.0.F USER"
      w "$H" list 2>/dev/null | tr -d '\r' | head -20 | sed 's/^/   /' ;;
    *) echo "unknown step $s" >&2 ;;
  esac
done
