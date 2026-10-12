#!/usr/bin/env bash
# D6: installs Revit 2020 component by component, bypassing the Setup.exe wizard.
# Order and paths come from Setup.ini: PREREQUISITE → INSTALL_SEQUENCE → POSTREQUISITE.
# Usage: ./scripts/d6-install-revit.sh <bottle> [steps...]
#   default steps: licensing svcshim adsso rcl rvt ret materials register ncryptshim ssoenv wbemshim richedit dynamo d3d9dxvk warpshim pdfprinter tlbpin samples
#   SSO_DEBUG=1 — also expose the sign-in browser's DevTools on 127.0.0.1:9222 (tools/cdp.py)
#   UI language: REVIT_LANG=en-US (default) | ru-RU
set -uo pipefail

NAME="${1:?specify a bottle}"; shift
STEPS=("$@"); [ ${#STEPS[@]} -eq 0 ] && STEPS=(licensing svcshim adsso rcl rvt ret materials register ncryptshim ssoenv wbemshim richedit dynamo d3d9dxvk warpshim pdfprinter tlbpin samples)
LANG_UI="${REVIT_LANG:-en-US}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
DIST_UNIX="$(ls -d "$ROOT"/installers/extracted/revit2020/*/ | head -1)"
DIST="Z:$(echo "${DIST_UNIX%/}" | tr '/' '\\')"
RUN="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$ROOT/logs/d6-$NAME-$RUN"; mkdir -p "$LOGDIR"
w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
# What the Setup.exe wizard normally passes to the MSIs. Without ADSK_SETUP_EXE the
# LaunchCondition "Installed or ADSK_SETUP_EXE" fails (msiexec exit=67, silently).
# Setup.exe builds INSTALLDIR from INSTALL_PATH (Setup.ini) + ADSK_INSTALL_PATH; in the MSI it is relative.
PRODKEY=829L1; PRODVER=2020.0.0.F
SETUP_PROPS=(ADSK_SETUP_EXE=1 ADSK_EULA_STATUS=#1 ADLM_PRODKEY=$PRODKEY ADLM_EULA_COUNTRY=US)

msi() { # $1 = step name, $2 = MSI path inside the installer, rest = KEY=VALUE properties
  # `wine msiexec args...` can't pass values with spaces: the CrossOver wrapper escapes
  # quotes as \", which Wine's msiexec parser doesn't understand, so it splits on spaces (→ 1639).
  # So write the exact command line to a .cmd and run it via cmd /c.
  local step="$1" rel="$2"; shift 2
  local t0=$(date +%s) line="msiexec /i \"$DIST\\$rel\" /qn /norestart ALLUSERS=1" a
  for a in "$@"; do
    case "$a" in *" "*) line+=" ${a%%=*}=\"${a#*=}\"" ;; *) line+=" $a" ;; esac
  done
  line+=" /l*v \"C:\\d6-$step.log\""
  printf '@echo off\r\n%s\r\nexit /b %%ERRORLEVEL%%\r\n' "$line" > "$B/drive_c/d6-$step.cmd"
  cp "$B/drive_c/d6-$step.cmd" "$LOGDIR/$step.cmd"
  w cmd /c "C:\\d6-$step.cmd" >>"$LOGDIR/wine.log" 2>&1
  local rc=$?
  rm -f "$B/drive_c/d6-$step.cmd"
  mv "$B/drive_c/d6-$step.log" "$LOGDIR/$step.msi.log" 2>/dev/null
  printf '   %-10s exit=%-5s %4ss  %s\n' "$step" "$rc" "$(( $(date +%s) - t0 ))" "$rel" | tee -a "$LOGDIR/summary.txt"
}

[ -d "$B" ] || { echo "no bottle $NAME" >&2; exit 1; }
# The wine process cwd = the script's cwd. Otherwise relative MSI paths (INSTALLDIR without Setup.exe)
# put files in the current folder (2.6 GB of Revit once landed in the repo root this way).
cd "$B/drive_c"
echo ">> bottle $NAME, language $LANG_UI, logs: $LOGDIR"
# Wine returns the msiexec code as its low byte: 67 = 1603 (fatal error), 103 = 1639 (invalid command line),
# 194 = 3010 (reboot needed). Properties with spaces only as PROP="value".
echo ">> 0 = ok, 194 (=3010) = ok+reboot, 67 (=1603) = fatal, 103 (=1639) = bad arguments"

for s in "${STEPS[@]}"; do
  case "$s" in
    licensing) # BitRock InstallBuilder
      t0=$(date +%s)
      w "$DIST\\x86\\AdskLicensing\\AdskLicensing-installer.exe" --mode unattended --unattendedmodeui none >>"$LOGDIR/wine.log" 2>&1
      # exit 1 is expected under Wine: only its takeown/sc sdshow calls fail; the service itself comes from svcshim
      rc=$?; [ $rc = 1 ] && rc=ok
      printf '   %-10s exit=%-5s %4ss  %s\n' licensing "$rc" "$(( $(date +%s) - t0 ))" "x86\\AdskLicensing\\AdskLicensing-installer.exe" | tee -a "$LOGDIR/summary.txt"
      cp "$B"/drive_c/users/crossover/AppData/Local/Temp/AdskLicensing-install.log "$LOGDIR/" 2>/dev/null || true
      # exit=1 is expected: Wine lacks takeown and `sc sdshow` (1639) — ACL steps, not critical.
      # mklink /J under Wine creates an empty "Current<garbage>" folder instead of a junction → fix with a symlink.
      AL="$B/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
      for f in "$AL"/Current?*; do [ -d "$f" ] && [ ! -L "$f" ] && rmdir "$f" 2>/dev/null; done
      ver="$(ls "$AL" | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1)"
      ln -sfn "$ver" "$AL/Current" && echo "   licensing  Current -> $ver (mklink fix)" ;;
    svcshim) # shim service, see tools/AdskSvcShim.cs
      SHIM_DIR="$B/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
      cp "$ROOT/tools/AdskSvcShim.cs" "$B/drive_c/AdskSvcShim.cs"
      w 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /out:'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\AdskSvcShim.exe' \
        /r:System.ServiceProcess.dll 'C:\AdskSvcShim.cs' >>"$LOGDIR/svcshim.log" 2>&1
      rm -f "$B/drive_c/AdskSvcShim.cs"
      [ -f "$SHIM_DIR/AdskSvcShim.exe" ] || { echo "   svcshim   build failed, see $LOGDIR/svcshim.log"; continue; }
      # sc config binPath= doesn't change the path under Wine → write ImagePath to the registry directly.
      # SCM reads service config only at startup → restart wineserver.
      w reg add 'HKLM\System\CurrentControlSet\Services\AdskLicensingService' /v ImagePath /t REG_EXPAND_SZ \
        /d '"C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\AdskSvcShim.exe"' /f >>"$LOGDIR/svcshim.log" 2>&1
      WINEPREFIX="$B" "$CX/bin/wineserver" -k 2>/dev/null
      # no --wait-children: the service never exits, we'd hang
      "$CX/bin/wine" --bottle "$NAME" sc start AdskLicensingService >>"$LOGDIR/svcshim.log" 2>&1 &
      for i in $(seq 1 20); do
        st="$("$CX/bin/wine" --bottle "$NAME" sc query AdskLicensingService 2>/dev/null | tr -d '\r' | awk '/STATE/{print $4}')"
        [ "$st" = RUNNING ] && break; perl -e 'select(undef,undef,undef,2)'
      done
      echo "   svcshim    AdskLicensingService: ${st:-?}" | tee -a "$LOGDIR/summary.txt" ;;
    adsso)     msi adsso     'x64\AdSSO\AdSSO.msi' ;;
    rcl)       msi rcl       'x64\RCL\RCL.msi' "TRANSFORMS=:$LANG_UI.mst" "${SETUP_PROPS[@]}" \
                 'INSTALLDIR=C:\Program Files\Autodesk\Revit Content 2020' ;;
    rvt) # RVT-wine.msi comes from scripts/patch-rvt-msi.sh: the licIsSvcUpgraded service check
         # (InstHelper upgrade isUpgraded, always exit 100 under Wine) is disabled with CLM_SKIP_SVCCHECK=1
      [ -f "$DIST_UNIX/x64/RVT/RVT-wine.msi" ] || "$ROOT/scripts/patch-rvt-msi.sh" "$NAME"
      msi rvt 'x64\RVT\RVT-wine.msi' "TRANSFORMS=:$LANG_UI.mst;:all.mst" "${SETUP_PROPS[@]}" CLM_SKIP_SVCCHECK=1 \
        'INSTALLDIR=C:\Program Files\Autodesk\Revit 2020' ;;
    ret)       msi ret       'x64\RET\RET.msi' ;;
    materials) # minimal set: material library + base image library
      msi cm2020   'Content\ADSKMaterials\2020\CM\MaterialLibrary2020.msi'
      msi cmilb    'Content\ADSKMaterials\2020\ILB\BaseImageLibrary2020.msi'
      msi cmplb    "Content\\ADSKMaterials\\2020\\PLB\\$(ls "$DIST_UNIX/Content/ADSKMaterials/2020/PLB" | grep -i '\.msi$' | head -1)" ;;
    register) # register the product with AdskLicensing, as Setup.exe does after install
      PIT_DIR="$B/drive_c/ProgramData/Autodesk/Revit/Revit 2020/Setup"
      mkdir -p "$PIT_DIR" && cp "$DIST_UNIX/Setup/RevitConfig.pit" "$PIT_DIR/"
      w 'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\helper\AdskLicensingInstHelper.exe' \
        register --pk "$PRODKEY" --pv "$PRODVER" --el US --lm USER \
        --cf 'C:\ProgramData\Autodesk\Revit\Revit 2020\Setup\RevitConfig.pit' >>"$LOGDIR/register.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' register "$?" "$PRODKEY $PRODVER USER" | tee -a "$LOGDIR/summary.txt"
      w 'C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing\Current\helper\AdskLicensingInstHelper.exe' \
        list 2>/dev/null | tr -d '\r' | sed 's/^/   /' | head -20 ;;
    ncryptshim) # ncrypt shim for Revit.exe: PersistenceDB ECDSA key via bcrypt (tools/ncrypt-shim)
      [ -f "$ROOT/build/ncrypt-shim/ncrypt.dll" ] || "$ROOT/scripts/build-ncrypt-shim.sh" >/dev/null
      cp "$ROOT/build/ncrypt-shim/ncrypt.dll" "$B/drive_c/Program Files/Autodesk/Revit 2020/ncrypt.dll"
      w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v ncrypt /d native,builtin /f >>"$LOGDIR/ncryptshim.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' ncryptshim "$?" "Revit 2020\\ncrypt.dll + AppDefaults\\Revit.exe ncrypt=native,builtin" | tee -a "$LOGDIR/summary.txt" ;;
    ssoenv) # AdSSO sign-in window (QtWebEngine 5.9): loads forever under Wine with GPU rendering, works without it
      env_args=('QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu --disable-gpu-compositing')
      if [ "${SSO_DEBUG:-0}" = 1 ]; then
        env_args+=('QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9222' 'QT_LOGGING_RULES=js.debug=true;qt.webengine*.debug=true')
      else
        env_args+=('-QTWEBENGINE_REMOTE_DEBUGGING' '-QT_LOGGING_RULES')
      fi
      "$ROOT/scripts/bottle-env.sh" "$NAME" "${env_args[@]}" | sed 's/^/   ssoenv     /' | tee -a "$LOGDIR/summary.txt" ;;
    wbemshim) # WMI shim: several async queries on one IWbemServices (tools/wbem-shim)
      # Affects all 64-bit processes in the bottle (changes the CLSID_WbemLocator registration).
      [ -f "$ROOT/build/wbem-shim/wbemshim.dll" ] || "$ROOT/scripts/build-wbem-shim.sh" >/dev/null
      cp "$ROOT/build/wbem-shim/wbemshim.dll" "$B/drive_c/windows/system32/wbem/wbemshim.dll"
      w reg add 'HKLM\Software\Classes\CLSID\{4590F811-1D3A-11D0-891F-00AA004B2E24}\InprocServer32' /ve \
        /d 'C:\windows\system32\wbem\wbemshim.dll' /f >>"$LOGDIR/wbemshim.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' wbemshim "$?" "CLSID_WbemLocator (x64) -> system32\\wbem\\wbemshim.dll" | tee -a "$LOGDIR/summary.txt" ;;
    richedit) # native x64 RichEdit (Win7 SP1) for Revit.exe only: TOM in Wine's riched20 is stubs,
              # so RtfData == NULL and text in views crashes. riched20 delay-loads msls31.dll
              # (Line Services); Win7 SP1 has no x64 build — copy it manually from a licensed Windows 7/10 x64 install
              # (C:\Windows\System32\msls31.dll) to installers/redist/win7sp1/x64/.
      RX="$ROOT/installers/redist/win7sp1/x64"
      [ -f "$RX/riched20.dll" ] || "$ROOT/scripts/get-win7-richedit.sh" >/dev/null
      [ -f "$RX/msls31.dll" ] || { echo "no $RX/msls31.dll (x64, copy from a licensed Windows 7/10 x64 install)" >&2; exit 1; }
      for dll in riched20 usp10 msls31; do
        cp "$RX/$dll.dll" "$B/drive_c/Program Files/Autodesk/Revit 2020/$dll.dll"
        # Revit loads riched20 by its full system32 path → put it there too; Wine's builtin stub goes to .wine-fake.
        # Other programs in the bottle load system DLLs builtin-first and won't notice.
        S32="$B/drive_c/windows/system32/$dll.dll"
        if LC_ALL=C grep -q -a 'Wine builtin DLL' "$S32" 2>/dev/null; then cp "$S32" "$S32.wine-fake"; fi
        cp "$RX/$dll.dll" "$S32"
        w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v "$dll" /d native,builtin /f >>"$LOGDIR/richedit.log" 2>&1
      done
      printf '   %-10s exit=%-5s %s\n' richedit "$?" "riched20 usp10 msls31 → Revit 2020\\ (AppDefaults Revit.exe native,builtin)" | tee -a "$LOGDIR/summary.txt" ;;
    wpfsw) # (not default; Dynamo switches to software WPF itself via UseHardwareAcceleration=false — dynamo step)
           # WPF without hardware acceleration for all of Revit: CrossOver's D3D9 goes wined3d → OpenGL and the GL thread hangs
           # (Dynamo window: main thread waits for the WPF render thread, which waits for wined3d, which waits for opengl32). Revit 3D (D3D11/D3DMetal) is unaffected.
      w reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >>"$LOGDIR/wpfsw.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' wpfsw "$?" "Avalon.Graphics DisableHWAcceleration=1" | tee -a "$LOGDIR/summary.txt" ;;
    wpfhw) # revert wpfsw
      w reg delete 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /f >>"$LOGDIR/wpfhw.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' wpfhw "$?" "Avalon.Graphics DisableHWAcceleration removed" | tee -a "$LOGDIR/summary.txt" ;;
    d3d9dxvk) # D3D9 for Revit.exe via DXVK (Vulkan→MoltenVK) instead of wined3d (OpenGL): the material browser (OGS DX9) under wined3d
              # crashes on GL_INVALID_FRAMEBUFFER_OPERATION. D3D11 (3D views) stays on D3DMetal.
      # WPF (wpfgfx) loads d3d9 by its full system32 path — like riched20, put it there too; Wine's stub goes to .wine-fake.
      # The DLL from lib/dxvk is marked "Wine builtin DLL" → the loader swaps in Wine's builtin d3d9 (find_builtin_dll).
      # Overwrite the marker in the copy — then it's a plain native DLL.
      DX="$LOGDIR/d3d9-dxvk-native.dll"
      python3 -I -c 'import sys; d=bytearray(open(sys.argv[1],"rb").read()); i=d.find(b"Wine builtin DLL"); assert 0<i<0x100, i; d[i:i+16]=b"DXVK native  DLL"; open(sys.argv[2],"wb").write(d)' \
        "$CX/lib/dxvk/x86_64-windows/d3d9.dll" "$DX"
      cp "$DX" "$B/drive_c/Program Files/Autodesk/Revit 2020/d3d9.dll"
      S32="$B/drive_c/windows/system32/d3d9.dll"
      if ! LC_ALL=C grep -q -a -i dxvk "$S32" 2>/dev/null; then cp "$S32" "$S32.wine-fake"; fi
      cp "$DX" "$S32"
      w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v d3d9 /d native,builtin /f >>"$LOGDIR/d3d9dxvk.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' d3d9dxvk "$?" "DXVK d3d9.dll → Revit 2020\\ (AppDefaults Revit.exe d3d9=native,builtin)" | tee -a "$LOGDIR/summary.txt" ;;
    dynamo) # Dynamo 2.3: the 3D preview (HelixToolkit.SharpDX) calls IDXGIResource::GetSharedHandle → E_NOTIMPL in D3DMetal → crash.
            # Disable Dynamo's hardware acceleration and background 3D preview; keep the preview in Revit views (IsRevitBackgroundPreviewActive).
            # Dynamo creates the file on first run; if it's missing, write a minimal one.
      DS="$B/drive_c/users/crossover/AppData/Roaming/Dynamo/Dynamo Revit/2.3/DynamoSettings.xml"
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
      printf '   %-10s exit=%-5s %s\n' dynamo "$?" "DynamoSettings.xml: UseHardwareAcceleration=false, IsBackgroundPreviewActive=false" | tee -a "$LOGDIR/summary.txt" ;;
    warpshim) # the material browser requires D3D11 WARP ("Dx11_WARP"), which D3DMetal lacks → Materials won't open.
              # d3dwp.dll (tools/d3d11-warp-shim) replaces WARP with HARDWARE; in OGSDeviceDX11.dll the name L"D3D11.dll"
              # is replaced with L"d3dwp.dll" (same length). Original kept as OGSDeviceDX11.dll.orig.
      RD="$B/drive_c/Program Files/Autodesk/Revit 2020"
      [ -f "$ROOT/build/d3dwp/d3dwp.dll" ] || "$ROOT/scripts/build-d3dwp.sh" >/dev/null
      cp "$ROOT/build/d3dwp/d3dwp.dll" "$RD/d3dwp.dll"
      [ -f "$RD/OGSDeviceDX11.dll.orig" ] || cp "$RD/OGSDeviceDX11.dll" "$RD/OGSDeviceDX11.dll.orig"
      python3 -I - "$RD/OGSDeviceDX11.dll.orig" "$RD/OGSDeviceDX11.dll" >>"$LOGDIR/warpshim.log" 2>&1 <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
old, new = "D3D11.dll\0".encode("utf-16le"), "d3dwp.dll\0".encode("utf-16le")
n = d.count(old); assert n == 1, f"expected 1 occurrence of L'D3D11.dll', found {n}"
i = d.find(old); d[i:i+len(old)] = new
open(sys.argv[2], "wb").write(d); print("patched at", hex(i))
PY
      printf '   %-10s exit=%-5s %s\n' warpshim "$?" "d3dwp.dll + OGSDeviceDX11.dll: L\"D3D11.dll\" -> L\"d3dwp.dll\"" | tee -a "$LOGDIR/summary.txt" ;;
    pdfprinter) # "Revit PDF" printer: Wine PostScript driver + tools/pdf-printer/revitpdf.ppd (A4…A0, ARCH),
                # port REVITPDF: → |scripts/ps2pdf-port.sh (Ghostscript → ~/Documents/Revit-PDF). The Mac has no CUPS queues,
                # and without a printer Revit won't open Print/Page Setup.
      "$ROOT/scripts/build-add-printer.sh" >/dev/null
      mkdir -p "$B/drive_c/rvt-pdf"
      cp "$ROOT/build/pdf-printer/add_printer.exe" "$ROOT/tools/pdf-printer/revitpdf.ppd" "$B/drive_c/rvt-pdf/"
      # Wine's AddPrinterDriverEx copies only wineps.drv, and wineps looks for the PPD in the driver directory — copy it ourselves.
      mkdir -p "$B/drive_c/windows/system32/spool/drivers/x64/3"
      cp "$ROOT/tools/pdf-printer/revitpdf.ppd" "$B/drive_c/windows/system32/spool/drivers/x64/3/revitpdf.ppd"
      command -v gs >/dev/null || [ -x /opt/homebrew/bin/gs ] || echo "   warning: no Ghostscript (brew install ghostscript) — you will get .ps instead of .pdf" >&2
      {
        w reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Ports' /v 'REVITPDF:' /t REG_SZ /d '' /f
        w reg add 'HKCU\Software\Wine\Printing\Spooler' /v 'REVITPDF:' /t REG_SZ /d "|$ROOT/scripts/ps2pdf-port.sh" /f
        w regsvr32 /s wineps.drv
        w 'C:\rvt-pdf\add_printer.exe' 'Revit PDF' 'C:\rvt-pdf\revitpdf.ppd' 'REVITPDF:'
      } >>"$LOGDIR/pdfprinter.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' pdfprinter "$?" "Revit PDF → REVITPDF: → scripts/ps2pdf-port.sh" | tee -a "$LOGDIR/summary.txt" ;;
    samples) # copies of the samples for tests in C:\rvt-tests (originals in Samples untouched)
      mkdir -p "$B/drive_c/rvt-tests"
      cp "$B/drive_c/Program Files/Autodesk/Revit 2020/Samples/"rac_basic_sample_{project.rvt,family.rfa} "$B/drive_c/rvt-tests/"
      printf '   %-10s exit=%-5s %s\n' samples "$?" "Samples\\rac_basic_sample_* → C:\\rvt-tests" | tee -a "$LOGDIR/summary.txt" ;;
    tlbpin) # hook oleaut32!LoadRegTypeLib for the TOM typelib in Revit.exe: otherwise native riched20 re-parses it for every text
            # (Wine doesn't cache released ITypeLibs) — view creation is 2–3x slower than on Windows.
            # Also reuses win32u!NtUserGetCursorPos for 10 ms: long edits poll the mouse, ~12 us per call while it is still.
            # The msls31.dll shim (tools/tlbpin) forwards everything to the real msls31_ms.dll. Run after richedit.
      "$ROOT/scripts/build-tlbpin.sh" >/dev/null
      RX="$ROOT/installers/redist/win7sp1/x64"
      for d in "$B/drive_c/windows/system32" "$B/drive_c/Program Files/Autodesk/Revit 2020"; do
        cp "$RX/msls31.dll" "$d/msls31_ms.dll"; cp "$ROOT/build/tlbpin/msls31.dll" "$d/msls31.dll"
      done
      { w reg add 'HKCU\Software\Wine\AppDefaults\Revit.exe\DllOverrides' /v msls31_ms /d native,builtin /f
        w reg delete 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Windows' /v AppInit_DLLs /f
        w reg delete 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Windows' /v LoadAppInit_DLLs /f
        rm -f "$B/drive_c/windows/system32/tlbpin.dll"
      } >>"$LOGDIR/tlbpin.log" 2>&1
      printf '   %-10s exit=%-5s %s\n' tlbpin 0 "msls31.dll (shim + TOM LoadRegTypeLib and cursor position caches) → msls31_ms.dll" | tee -a "$LOGDIR/summary.txt" ;;
    *) echo "unknown step $s" >&2 ;;
  esac
done

echo ">> what got installed"
ls "$B/drive_c/Program Files/Autodesk" 2>/dev/null | sed 's/^/   Program Files\\Autodesk\\/'
ls "$B/drive_c/Program Files/Autodesk/Revit 2020/Revit.exe" 2>/dev/null && echo "   Revit.exe is in place"
w sc query AdskLicensingService 2>/dev/null | tr -d '\r' | grep -E 'SERVICE_NAME|STATE' | sed 's/^/   /'
