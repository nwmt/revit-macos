# Install steps: our fixes for Wine inside Revit — shims, Microsoft's RichEdit, DXVK for Direct3D 9, the WebView2
# browser, the PDF printer. Nothing changes an Autodesk file on disk. Sourced by scripts/run-steps.sh.

step_ncryptshim() { # Wine's ncrypt cannot import a private ECDSA P-256 key (ECCPRIVATEBLOB) → assert in
  # PersistenceDB\DataIntegrity.cpp:52 and "unrecoverable error" at startup. Our ncrypt.dll (tools/shims/ncryptshim), for
  # Revit.exe only
  ensure_shim ncryptshim || return 1
  cp "$(shim_dir)/ncryptshim/ncrypt.dll" "$RD/ncrypt.dll" || return 1
  app_override Revit.exe ncrypt || return 1
  detail "Revit $YEAR\\ncrypt.dll + AppDefaults\\Revit.exe ncrypt=native,builtin"
}

step_rvtfix() { # Wine fixes inside the Revit process (tools/shims/rvtfix, loaded by our ncrypt.dll: run after ncryptshim),
  # made in memory: drag and drop on another process's window (WebView2 start screen), WebView2 and CefSharp browser
  # flags, OGSDeviceDX11.dll loading d3dwp.dll (warpshim), USER32!IsWindow for DesktopMFC.dll. Bottles from before
  # patched those two files on disk: the originals (.orig) go back. RVTFIX_ENV (profile): bottle settings for it
  local f
  for f in OGSDeviceDX11.dll DesktopMFC.dll; do [ ! -f "$RD/$f.orig" ] || mv -f "$RD/$f.orig" "$RD/$f" || return 1; done
  ensure_shim ncryptshim && ensure_shim rvtfix || return 1
  cp "$(shim_dir)/ncryptshim/ncrypt.dll" "$(shim_dir)/rvtfix/rvtfix.dll" "$RD/" || return 1
  [ ${#RVTFIX_ENV[@]} -eq 0 ] || bottle_env "${RVTFIX_ENV[@]}" || return 1
  detail "rvtfix.dll + ncrypt.dll (loads rvtfix) → Revit $YEAR${RVTFIX_ENV[0]:+; ${RVTFIX_ENV[*]}}"
}

step_warpshim() { # the material browser needs a D3D11 WARP device, which D3DMetal lacks ("Can't get OGS device …
  # Material Browser dialog can't be created"). d3dwp.dll (tools/shims/d3dwp) asks for HARDWARE instead; rvtfix
  # makes OGSDeviceDX11.dll load it. Material previews come from AdPreviewGenerator.exe, a process of its own ("OGS
  # ERROR: no virtual device", then a crash): our version.dll loads rvtfix.dll from Revit's folder there too
  ensure_shim d3dwp || return 1
  cp "$(shim_dir)/d3dwp/d3dwp.dll" "$RD/d3dwp.dll" || return 1
  wv2fix_install AdPreviewGenerator.exe || return 1
  detail "d3dwp.dll → Revit $YEAR (rvtfix points OGSDeviceDX11.dll at it); AppDefaults AdPreviewGenerator.exe version=native,builtin"
}

step_wbemshim() { # WMI: several async queries on one IWbemServices (tools/shims/wbemshim); Revit's System Inventory crashes
  # without it. Changes the CLSID_WbemLocator registration: all 64-bit processes in the bottle get it
  ensure_shim wbemshim || return 1
  cp "$(shim_dir)/wbemshim/wbemshim.dll" "$B/drive_c/windows/system32/wbem/wbemshim.dll" || return 1
  w reg add 'HKLM\Software\Classes\CLSID\{4590F811-1D3A-11D0-891F-00AA004B2E24}\InprocServer32' /ve \
    /d 'C:\windows\system32\wbem\wbemshim.dll' /f || return 1
  detail "CLSID_WbemLocator (x64) → system32\\wbem\\wbemshim.dll"
}

step_richedit() { # Microsoft's x64 RichEdit (Windows 7 SP1) for Revit.exe: TOM in Wine's RichEdit is stubs, and text
  # in views crashes Revit. msftedit and riched20 delay-load msls31 and usp10; x64 msls31 comes from a licensed
  # Windows 7/10 x64 PC (installers/README.md). msftedit goes into system32 only: Revit looks in its own folder first,
  # but the system32 copy is already loaded by then, and a second copy fails to register its window classes
  local rx="$DATA/installers/redist/win7sp1/x64" dll dir
  [ -f "$rx/riched20.dll" ] || "$ROOT/scripts/get-win7-richedit.sh" || return 1
  [ -f "$rx/msls31.dll" ] || { echo "no $rx/msls31.dll (x64, from a licensed Windows 7/10 x64 PC)"; return 1; }
  rm -f "$RD/msftedit.dll"
  for dll in "${RICHEDIT[@]}"; do
    dir="$RD"; [ "$dll" = msftedit ] && dir=""
    put_native_dll "$dll" "$rx/$dll.dll" "$dir" Revit.exe || return 1
  done
  detail "${RICHEDIT[*]} → Revit $YEAR + system32 (AppDefaults Revit.exe native,builtin)"
}

step_tlbpin() { # LoadRegTypeLib(LIBID_tom) and cursor position caches for Revit.exe (tools/shims/tlbpin, built as msls31.dll,
  # forwards to Microsoft's msls31_ms.dll): otherwise the TOM typelib is parsed again for every text and views are
  # created 2–3× slower. Run after richedit
  local rx="$DATA/installers/redist/win7sp1/x64" d
  ensure_shim tlbpin || return 1
  for d in "$B/drive_c/windows/system32" "$RD"; do cp "$rx/msls31.dll" "$d/msls31_ms.dll" || return 1; done
  put_native_dll msls31 "$(shim_dir)/tlbpin/msls31.dll" "$RD" || return 1
  app_override Revit.exe msls31_ms || return 1
  detail "msls31.dll (shim: TOM and cursor caches) → msls31_ms.dll"
}

step_d3d9dxvk() { # Direct3D 9 (WPF panels, OGS DX9) through wined3d → GL_INVALID_FRAMEBUFFER_OPERATION and a crash:
  # DXVK's d3d9.dll for Revit.exe instead. Its "Wine builtin DLL" marker would make Wine load its own d3d9: the copy
  # gets another marker (tools/pe_mark.py)
  local dx="$RUN_DIR/d3d9-dxvk-native.dll"
  python3 -I "$ROOT/tools/pe_mark.py" "$CX/lib/dxvk/x86_64-windows/d3d9.dll" "$dx" "DXVK native  DLL" || return 1
  put_native_dll d3d9 "$dx" "$RD" Revit.exe || return 1
  detail "DXVK d3d9.dll → Revit $YEAR + system32 (AppDefaults Revit.exe d3d9=native,builtin)"
}

wv2fix_install() { # tools/shims/wv2fix as version.dll in system32, native for the exes given ($@); it also loads
  # rvtfix.dll that sits next to the exe. Used by wv2fix, warpshim and Enscape 4 (addins)
  local s32="$B/drive_c/windows/system32" orig="$RUN_DIR/version_orig.dll"
  ensure_shim wv2fix || return 1
  # version_orig.dll: Wine's builtin version.dll without the marker (otherwise the loader swaps it), our DLL forwards to it
  python3 -I "$ROOT/tools/pe_mark.py" "$CX/lib/wine/x86_64-windows/version.dll" "$orig" "Wine orig    DLL" || return 1
  cp "$orig" "$s32/version_orig.dll.new" && mv -f "$s32/version_orig.dll.new" "$s32/version_orig.dll" || return 1
  put_native_dll version "$(shim_dir)/wv2fix/version.dll" "" "$@" || return 1
  rm -f "$B/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/"[0-9]*/version*.dll   # an older variant
}

step_wv2fix() { # the WebView2 browser inside Revit crashes ("holding USER lock") when a window nested in Revit's
  # changes (Chromium's redraw lock, CrossOver 26.3): the start screen "reloads", the 2027 Project Browser stays empty.
  # tools/shims/wv2fix skips that change and flushes the window first. The browser loads system DLLs only from system32
  wv2fix_install msedgewebview2.exe || return 1
  detail "version.dll (+ version_orig.dll) → system32; AppDefaults msedgewebview2.exe version=native,builtin"
}

pdf_port_script() { # the printer port runs this path for every print job; it is stored in the bottle, so it must not
  # point into the app (moving the app would break printing): with a data folder of its own, a copy lives there
  if [ "$DATA" = "$ROOT" ]; then echo "$ROOT/scripts/ps2pdf-port.sh"; return 0; fi
  # the content into a new file: a copy (even cp -X) keeps the quarantine attribute of a downloaded app
  mkdir -p "$DATA/libexec" && cat "$ROOT/scripts/ps2pdf-port.sh" > "$DATA/libexec/ps2pdf-port.sh.new" \
    && chmod +x "$DATA/libexec/ps2pdf-port.sh.new" && mv -f "$DATA/libexec/ps2pdf-port.sh.new" "$DATA/libexec/ps2pdf-port.sh" \
    && echo "$DATA/libexec/ps2pdf-port.sh"
}

step_pdfprinter() { # "Revit PDF": Wine's PostScript driver + tools/shims/pdfprinter/revitpdf.ppd (A4…A0, ARCH), port
  # REVITPDF: → |scripts/ps2pdf-port.sh (Ghostscript → ~/Documents/Revit-PDF). The Mac has no CUPS queues, and without
  # a printer Revit does not open Print or Page Setup
  local note="" port
  ensure_shim pdfprinter || return 1
  mkdir -p "$B/drive_c/rvt-pdf" "$B/drive_c/windows/system32/spool/drivers/x64/3" || return 1
  cp "$(shim_dir)/pdfprinter/add_printer.exe" "$ROOT/tools/shims/pdfprinter/revitpdf.ppd" "$B/drive_c/rvt-pdf/" || return 1
  # Wine's AddPrinterDriverEx copies only wineps.drv, and wineps looks for the PPD in the driver folder
  cp "$ROOT/tools/shims/pdfprinter/revitpdf.ppd" "$B/drive_c/windows/system32/spool/drivers/x64/3/revitpdf.ppd" || return 1
  w reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Ports' /v 'REVITPDF:' /t REG_SZ /d '' /f || return 1
  port="$(pdf_port_script)" || return 1
  w reg add 'HKCU\Software\Wine\Printing\Spooler' /v 'REVITPDF:' /t REG_SZ /d "|$(sh_path "$port")" /f || return 1
  w regsvr32 /s wineps.drv   # its code says nothing under Wine; add_printer fails below if the driver is missing
  w 'C:\rvt-pdf\add_printer.exe' 'Revit PDF' 'C:\rvt-pdf\revitpdf.ppd' 'REVITPDF:' || return 1
  command -v gs >/dev/null || [ -x /opt/homebrew/bin/gs ] || note=" (no Ghostscript: .ps instead of .pdf; brew install ghostscript)"
  detail "Revit PDF → REVITPDF: → $(tilde "$port")$note"
}
