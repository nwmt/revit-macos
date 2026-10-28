# Add-in steps: RevitLookup, pyRevit, trusting add-in publishers, software WPF, and Enscape (not default: bring your own
# installer). ./revit addins runs the year's ADDIN_STEPS; others: scripts/run-steps.sh <year> <bottle> <step…>.
# Installers are in installers/addins/ (installers/README.md). Sourced by scripts/run-steps.sh.

net_release() { w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>/dev/null \
  | tr -d '\r' | awk '/Release/{print $3}' | xargs printf '%d\n' 2>/dev/null; }

step_revitlookup() {
  local f="$DATA/installers/addins/$LOOKUP" rc
  [ -n "$LOOKUP" ] || { skip "RevitLookup is not set up for Revit $YEAR"; return 0; }
  [ -f "$f" ] || { addin_load revitlookup && addin_fetch revitlookup; } || { echo "no installers/addins/$LOOKUP (installers/README.md, Add-ins)"; return 1; }
  cp "$f" "$B/drive_c/RevitLookup.msi" || return 1
  w msiexec /i 'C:\RevitLookup.msi' /qn /l*v 'C:\revitlookup.msi.log'; rc=$?
  rm -f "$B/drive_c/RevitLookup.msi"; mv "$B/drive_c/revitlookup.msi.log" "$RUN_DIR/" 2>/dev/null
  accept_codes "$rc" 0 194 || { echo "the RevitLookup MSI returned $rc"; return 1; }
  detail "$(basename "$LOOKUP")"
}

step_pyrevit() { # pyRevit 4.8.12 for 2020 (its IPY277 engine runs on .NET 4.7; 6.5.5 needs 4.7.1+), 7.0 for 2023–2027.
  # The 4.8 installer runs `attach master 277 --installed` but does not find Revit 2020: PYREVIT_ATTACH attaches it
  local f="$DATA/installers/addins/$PYREVIT" rc pyr='C:\users\crossover\AppData\Roaming\pyRevit-Master\bin\pyrevit.exe'
  [ -n "$PYREVIT" ] || { skip "pyRevit is not set up for Revit $YEAR"; return 0; }
  [ -f "$f" ] || { addin_load pyrevit && addin_fetch pyrevit; } || { echo "no installers/addins/$PYREVIT (installers/README.md, Add-ins)"; return 1; }
  run_exe pyRevit-setup "$f" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- '/LOG=C:\pyrevit-setup.log'; rc=$?
  mv "$B/drive_c/pyrevit-setup.log" "$RUN_DIR/" 2>/dev/null
  accept_codes "$rc" 0 || { echo "the pyRevit installer returned $rc"; return 1; }
  [ -z "$PYREVIT_ATTACH" ] || w "$pyr" attach master "$PYREVIT_ATTACH" "$YEAR" || return 1
  # 4.8 leaves only the admin config in ProgramData and copies it to the user's on Revit start; under Wine that copy
  # does not happen and every setting lives in memory only (lost on Reload). The copy is made here, an existing one kept
  local adm="$B/drive_c/ProgramData/pyRevit/pyRevit_config.ini" usr="$B/$PYREVIT_CONFIG_REL"
  case "$PYREVIT" in pyrevit48/*)
    [ -e "$usr" ] || [ ! -f "$adm" ] || { mkdir -p "$(dirname "$usr")" && cp "$adm" "$usr"; } || return 1 ;;
  esac
  w "$pyr" attached | tr -d '\r'
  detail "$(basename "$PYREVIT")"
}

step_trust() { # "This signed add-in has been found" → "Always Load" puts the signer's certificate into the user's
  # TrustedPublisher store; under Wine that write does not happen, so Revit asks on every start. Done here for the
  # assemblies the .addin manifests in the Addins folders name (absolute, or relative to the manifest); trust is per
  # publisher, so it covers their other add-ins too
  local files=() m a f d rc
  while IFS= read -r d; do
    for m in "$d"/*.addin; do
      [ -f "$m" ] || continue
      while IFS= read -r a; do
        case "$a" in [A-Za-z]:\\*) f="$B/drive_c/$(echo "${a:3}" | tr '\\' /)" ;; *) f="$(dirname "$m")/$(echo "$a" | tr '\\' /)" ;; esac
        [ -f "$f" ] && files+=("$f")
      done < <(grep -o '<Assembly>[^<]*' "$m" | sed 's/<Assembly>//' | tr -d '\r')
    done
  done < <(addin_dirs)
  [ ${#files[@]} -gt 0 ] || { skip "no add-in assemblies"; return 0; }
  python3 -I "$ROOT/tools/trustpub.py" "$B/drive_c/trust.reg" "${files[@]}" || return 1
  w regedit /s 'C:\trust.reg'; rc=$?
  mv "$B/drive_c/trust.reg" "$RUN_DIR/"
  [ "$rc" = 0 ] || return 1
  detail "publishers of ${#files[@]} add-in file(s)"
}

step_wpfsw() { # add-in windows (pyRevit, RevitLookup) use WPF effects whose D3D9 shaders fail through DXVK → MoltenVK
  # ("DxvkGraphicsPipeline: Failed to compile pipeline") → black rectangles all over Revit. Software WPF (a standard
  # Windows key); Revit's views are not affected
  w reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f || return 1
  detail "Avalon.Graphics DisableHWAcceleration=1"
}
step_wpfhw() { # undoes wpfsw; nothing to do when the value is not there (reg query: 0 = there, 1 = not there)
  local k='HKCU\Software\Microsoft\Avalon.Graphics' rc
  w reg query "$k" /v DisableHWAcceleration >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) w reg delete "$k" /v DisableHWAcceleration /f || return 1 ;;
    1) ;;
    *) echo "reg query returned $rc"; return 1 ;;
  esac
  detail "Avalon.Graphics DisableHWAcceleration removed"
}

step_check() { # the state, for a report: .NET Framework Release and the add-in manifests (listed in check.log)
  local d m n=0 rel
  rel="$(net_release)"; echo ".NET Framework Release=$rel"
  while IFS= read -r d; do
    for m in "$d"/*.addin; do [ -f "$m" ] && { echo "${m#"$B/"}"; n=$((n + 1)); }; done
  done < <(addin_dirs)
  detail ".NET Framework Release=$rel; $n add-in manifest(s)"
}

step_net48()  { net_full net48 "$DATA/installers/redist/dotnet48/ndp48-x86-x64-allos-enu.exe"; }
step_net472() { net_full net472 "$DATA/installers/redist/dotnet472/ndp472-KB4054530-x86-x64-AllOS-ENU.exe"; }
net_full() { # .NET Framework 4.7.2 or 4.8 over 2020's 4.7. Not default: Revit 2020 crashes in clr.dll on them (80131506)
  local before rc
  [ -f "$2" ] || { echo "no $2"; return 1; }
  before="$(net_release)"
  # on Windows 10 the installer treats 4.8/4.7.2 as built in and silently exits: install as Windows 7. No DLL
  # overrides: CrossOver's wine drops WINEDLLOVERRIDES (as in netfx_as_old_windows)
  w winecfg -v win7 || return 1
  run_exe ndp "$2" /q /norestart /log 'C:\ndp-setup'; rc=$?
  w winecfg -v win10 || return 1
  w wineboot -r   # the MSI asks for a reboot (pending file renames)
  cp "$B"/drive_c/ndp-setup* "$RUN_DIR/" 2>/dev/null; rm -f "$B"/drive_c/ndp-setup*
  accept_codes "$rc" 0 194 || { echo "the $1 installer returned $rc"; return 1; }
  detail "Release $before → $(net_release) (461808 = 4.7.2, 528040+ = 4.8)"
}

step_revitmcp() { mcp_install_variant revitmcp; }   # Autodesk's Revit MCP Server, Write-Tools (scripts/addins/revitmcp.sh)
step_revitmcp_experimental() { mcp_install_variant revitmcp-experimental; }

mcp_install_variant() { # $1 = id: the MCP Server variant from its ODIS installer, then ADP and our launcher (mcphost,
  # mcppipes) next to it (scripts/lib/mcp.sh). One variant per bottle: they share the add-in manifest
  local id="$1" other exe msi tmp rc sfx; sfx="$(bottle_sfx "$NAME" "$YEAR")"
  addin_load "$id" || return 1
  eula_ok "$id" || { echo "$MCP_NOTICE To accept: add --accept-eula $id (./revit addins $YEAR$sfx --only $id --accept-eula $id)"; return 1; }
  for other in revitmcp revitmcp-experimental; do
    [ "$other" != "$id" ] || continue
    if [ "$(mcp_installed_variant)" = "$other" ] || mcp_product_registered "$other"; then
      echo "Another variant of the Revit MCP Server ($other) is installed in this bottle, and only one can be. To switch: ./revit rebuild $YEAR$sfx, then install $id"
      return 1
    fi
  done
  mcp_adp_version >/dev/null || { echo "the Revit $YEAR installer is not unpacked: ./scripts/unpack-revit.sh $YEAR"; return 1; }
  if mcp_product_registered "$id" && [ -f "$(mcp_folder "$id")/$MCP_SERVER_EXE" ] && [ "$(mcp_installed_variant)" = "$id" ]; then
    echo "$ADDIN_NAME is installed; ADP and the launcher are checked"
  else
    exe="$DATA/installers/addins/$(mcp_field "$id" 4)"; msi="$(mcp_field "$id" 3)"
    [ -f "$exe" ] || { echo "no installers/addins/$(mcp_field "$id" 4) (./revit addins import $id <file>)"; return 1; }
    command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip"; return 1; }
    tmp="$(mktemp -d)" || return 1
    7zz x -y -o"$tmp" "$exe" "$(dirname "$msi")/*" >/dev/null && cp "$tmp/$msi" "$B/drive_c/$id.msi"; rc=$?
    rm -rf "$tmp"; [ $rc = 0 ] || { echo "could not take $msi out of $(basename "$exe")"; return 1; }
    if mcp_product_registered "$id"; then   # registered, but files or the manifest are gone: a repair puts them back
      msi_nowait "$id" "C:\\$id.msi" ADSK_SETUP_EXE=1 REINSTALL=ALL REINSTALLMODE=amus; rc=$?
    else
      msi_nowait "$id" "C:\\$id.msi" ADSK_SETUP_EXE=1; rc=$?
    fi
    rm -f "$B/drive_c/$id.msi"
    accept_codes "$rc" 0 194 || { echo "the $ADDIN_NAME MSI returned $rc"; return 1; }
  fi
  adp_install || return 1
  ensure_shim mcphost && ensure_shim mcppipes || return 1
  cp "$(shim_dir)/mcphost/mcphost.exe" "$(shim_dir)/mcppipes/mcppipes.dll" "$(mcp_folder "$id")/" || return 1
  mcp_ready "$id" || { echo "$ADDIN_NAME is not complete: $(mcp_missing "$id") is missing"; return 1; }
  detail "$ADDIN_NAME; ADP $(cat "$(mcp_adp_marker)"); mcphost and mcppipes"
}

adp_install() { # Autodesk analytics (ADP Desktop SDK), which the MCP Server's add-in requires, from the unpacked Revit
  # installer, its packages unchanged: InstallCustomAction action=pre → the ZIP into Common Files → action=post. The
  # marker (the package version) is written only after all three; it goes first, so a cut-short run repeats all three
  local v d m t rc
  v="$(mcp_adp_version)" || { echo "the Revit $YEAR installer is not unpacked: ./scripts/unpack-revit.sh $YEAR"; return 1; }
  d="$(mcp_dist)/x64/AdpSdk"; m="$(mcp_adp_marker)"; t="$(dirname "$(mcp_adp_core)")"
  [ "$(cat "$m" 2>/dev/null)" = "$v" ] && [ -f "$(mcp_adp_core)" ] && { echo "ADP $v is installed"; return 0; }
  rm -f "$m" || return 1
  run_exe InstallCustomAction "$d/InstallCustomAction.exe" action=pre > "$RUN_DIR/adp-pre.log" 2>&1; rc=$?
  [ $rc = 0 ] || { echo "ADP: InstallCustomAction action=pre returned $rc"; return 1; }
  mkdir -p "$t" && unzip -q -o "$d/adp-desktop-sdk.zip" -d "$t" || { echo "ADP: could not unpack adp-desktop-sdk.zip"; return 1; }
  run_exe InstallCustomAction "$d/InstallCustomAction.exe" action=post > "$RUN_DIR/adp-post.log" 2>&1; rc=$?
  [ $rc = 0 ] || { echo "ADP: InstallCustomAction action=post returned $rc"; return 1; }
  mkdir -p "$(dirname "$m")" && printf '%s\n' "$v" > "$m.tmp" && mv "$m.tmp" "$m"
}

step_enscape() { # Enscape with its fixes, for the version in the profile (ENSCAPE: 3 for 2020, 4 for 2027)
  case "$ENSCAPE" in
    3) enscape3 ;; 4) enscape4 ;;
    *) echo "Enscape is set up and tested for Revit 2020 and 2027 only"; return 1 ;;
  esac
}

enscape3() { # Enscape 3.4.4 (Revit 2019–2023). Without UI its MSI needs ACCEPTEULA=1 (LaunchCondition; otherwise a
  # silent 1603): it accepts the Enscape EULA — run this step only if you accept it
  local i="$DATA/installers" rc vt
  eula_ok enscape || { echo "The Enscape installer accepts the Enscape EULA. To accept it: REVIT_ACCEPT_EULA=enscape (./revit addins <year> --only enscape --accept-eula enscape)"; return 1; }
  [ -f "$i/addins/enscape/Enscape-3.4.4-94564.msi" ] || { echo "no installers/addins/enscape/Enscape-3.4.4-94564.msi"; return 1; }
  [ -f "$i/redist/nuget/system.valuetuple.4.5.0.nupkg" ] || { echo "no installers/redist/nuget/system.valuetuple.4.5.0.nupkg"; return 1; }
  cp "$i/addins/enscape/Enscape-3.4.4-94564.msi" "$B/drive_c/Enscape.msi" || return 1
  w msiexec /i 'C:\Enscape.msi' /qn /norestart ACCEPTEULA=1 '/l*v' 'C:\enscape.msi.log'; rc=$?
  rm -f "$B/drive_c/Enscape.msi"; mv "$B/drive_c/enscape.msi.log" "$RUN_DIR/" 2>/dev/null
  accept_codes "$rc" 0 194 || { echo "the Enscape MSI returned $rc"; return 1; }
  # Enscape ships System.ValueTuple 4.0.3.0 with its own types (net461). On .NET 4.7 ValueTuple is already in mscorlib
  # → two types → TypeLoadException when the plugin starts (grey icons). The net47 facade from the same NuGet package
  # forwards the types instead
  vt="$B/drive_c/Program Files/Enscape/Bin64/System.ValueTuple.dll"
  [ -f "$vt.orig" ] || cp "$vt" "$vt.orig" || return 1
  unzip -p "$i/redist/nuget/system.valuetuple.4.5.0.nupkg" lib/net47/System.ValueTuple.dll > "$vt" || return 1
  # Vulkan fixes (tools/shims/vkshim): Enscape's GPU check, its query pools and the focus of its view. Into system32: DXVK
  # (d3d9dxvk) loads vulkan-1.dll from there at Revit's start, before Enscape does
  ensure_shim vkshim || return 1
  put_native_dll vulkan-1 "$(shim_dir)/vkshim/vulkan-1.dll" "" Revit.exe || return 1
  # CrossOver builds MoltenVK with Metal argument buffers off (Enscape's shaders do not compile: black geometry) and
  # with asynchronous queue submits (Enscape hangs when its window is resized): back to MoltenVK's own defaults
  bottle_env MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 || return 1
  detail "Enscape 3.4.4; System.ValueTuple net47 facade; Vulkan fixes (system32\\vulkan-1.dll)"
}

enscape4() { # Enscape 4.18 LTS for Revit 2027; the renderer is its own process, Enscape.RendererHost.exe.
  # Chaos Installer without UI: -auto installs the default set (Enscape, Chaos Unified Login, Cosmos, …) and accepts the
  # Enscape EULA — run this step only if you accept it
  local i="$DATA/installers" s32="$B/drive_c/windows/system32" rc tmp svc n d c
  local a='HKCU\Software\Wine\AppDefaults\Enscape.RendererHost.exe\DllOverrides'
  eula_ok enscape || { echo "The Enscape installer accepts the Enscape EULA. To accept it: REVIT_ACCEPT_EULA=enscape (./revit addins <year> --only enscape --accept-eula enscape)"; return 1; }
  command -v 7zz >/dev/null || { echo "7zz required: brew install sevenzip"; return 1; }
  [ -f "$i/addins/enscape/Enscape-4.18.2.1657-lts.exe" ] || { echo "no installers/addins/enscape/Enscape-4.18.2.1657-lts.exe"; return 1; }
  run_exe Enscape-setup "$i/addins/enscape/Enscape-4.18.2.1657-lts.exe" -gui=0 -auto; rc=$?
  cp "$B/drive_c/users/crossover/AppData/Local/Enscape/Logs/Enscape.Installer/"*.log "$RUN_DIR/" 2>/dev/null
  [ -f "$B/drive_c/Program Files/Enscape/RendererHost/Enscape.RendererHost.exe" ] \
    || { echo "the Enscape installer returned $rc and Enscape is not installed"; return 1; }
  # its license check reads the computer's UUID through WMI with .NET's System.Management, which loads wminet_utils.dll
  # from .NET Framework 4.8; the 2027 bottle has no .NET Framework. The DLL and its two runtime DLLs come from the
  # .NET 4.8 installer Enscape ships (no .NET Framework install)
  tmp="$(mktemp -d)" || return 1
  7zz e -y -o"$tmp" "$B/drive_c/Program Files/Enscape/redist/ndp48-x86-x64-allos-enu.exe" netfx_Full.mzz >/dev/null &&
    7zz e -y -o"$tmp" "$tmp/netfx_Full.mzz" wminet_utils_dll_amd64 vcruntime140_clr0400_dll_amd64 ucrtbase_clr0400_dll_amd64 >/dev/null &&
    cp "$tmp/wminet_utils_dll_amd64" "$B/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/wminet_utils.dll" &&
    cp "$tmp/vcruntime140_clr0400_dll_amd64" "$s32/vcruntime140_clr0400.dll" &&
    cp "$tmp/ucrtbase_clr0400_dll_amd64" "$s32/ucrtbase_clr0400.dll"; rc=$?
  rm -rf "$tmp"; [ $rc = 0 ] || { echo "wminet_utils.dll from .NET 4.8 failed"; return 1; }
  # Vulkan fixes (tools/shims/vkshim): Enscape turns down the Mac GPU (logicOp); its view takes keys and the mouse only when active
  ensure_shim vkshim || return 1
  put_native_dll vulkan-1 "$(shim_dir)/vkshim/vulkan-1.dll" "" Enscape.RendererHost.exe || return 1
  # no Direct3D 11 for Enscape's own windows (Avalonia): through D3DMetal, closing a menu deadlocks with the renderer in
  # CrossOver's Mac driver; through any D3D the window's Metal layer hides the Asset Library browser. Without d3d11
  # Avalonia draws in software
  w reg add "$a" /v d3d11 /d '' /f || return 1
  # Asset Library is a WebView2 browser: it needs the same browser arguments as Revit's (tools/shims/rvtfix) from the start of
  # the process. Our version.dll (tools/shims/wv2fix) loads rvtfix.dll that sits next to the exe
  wv2fix_install msedgewebview2.exe || return 1
  ensure_shim rvtfix || return 1
  cp "$(shim_dir)/rvtfix/rvtfix.dll" "$B/drive_c/Program Files/Enscape/RendererHost/rvtfix.dll" || return 1
  app_override Enscape.RendererHost.exe version || return 1
  bottle_env MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1 MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1 || return 1
  # Chaos Unified Login (sign-in) and Cosmos (Asset Library) start from the Windows StartUp folder, which Wine does not
  # run: auto-start services through tools/shims/svcshim instead; Wine starts those with the bottle
  ensure_shim svcshim || return 1
  cp "$(shim_dir)/svcshim/svcshim.exe" "$B/drive_c/Program Files/Chaos/svcshim.exe" || return 1
  for svc in 'ChaosUnifiedLogin|Chaos Unified Login|"C:\Program Files\Chaos\UnifiedLogin\ulasupervisor.exe"' \
             'ChaosCosmos|Chaos Cosmos Browser|"C:\Program Files\Chaos\Cosmos\cbservice.exe" supervisor 0'; do
    IFS='|' read -r n d c <<<"$svc"; local k='HKLM\System\CurrentControlSet\Services\'"$n"
    w reg add "$k" /v Type /t REG_DWORD /d 16 /f && w reg add "$k" /v Start /t REG_DWORD /d 2 /f &&
      w reg add "$k" /v ErrorControl /t REG_DWORD /d 1 /f && w reg add "$k" /v ObjectName /d LocalSystem /f &&
      w reg add "$k" /v DisplayName /d "$d" /f &&
      w reg add "$k" /v ImagePath /t REG_EXPAND_SZ /d "\"C:\Program Files\Chaos\svcshim.exe\" $c" /f || return 1
  done
  wineserver_kill   # services start with the bottle; this also stops the installer's copies
  detail "Enscape 4.18 LTS; wminet_utils.dll; Vulkan fixes; d3d11 off and rvtfix for Enscape.RendererHost.exe; Chaos services"
}

enscape_manifest_dir() { if [ "$ENSCAPE" = 4 ]; then addin_dirs | sed -n 3p; else addin_dirs | sed -n 2p; fi; }
step_enscape-off() { # Enscape does not load (its manifest moves to Addins\<year>.off); its files stay
  local ad; ad="$(enscape_manifest_dir)"
  mkdir -p "$ad.off" || return 1
  [ ! -f "$ad/0_Enscape.addin" ] || mv "$ad/0_Enscape.addin" "$ad.off/" || return 1
  detail "0_Enscape.addin → $(basename "$ad").off"
}
step_enscape-on() { # Enscape loads again
  local ad; ad="$(enscape_manifest_dir)"
  [ ! -f "$ad.off/0_Enscape.addin" ] || mv "$ad.off/0_Enscape.addin" "$ad/" || return 1
  [ -f "$ad/0_Enscape.addin" ] || { echo "no 0_Enscape.addin in $ad"; return 1; }
  detail "0_Enscape.addin back in $(basename "$ad")"
}

step_pythonmcp() { # The MCP server for Revit (Python), add-in python-mcp (scripts/addins/python-mcp.sh): the patched
  # upstream extension in pyRevit's Extensions folder; pyRevit 4.8's Routes patch and our module beside it (the module
  # first: a server.py that imports it without it stops pyRevit loading); the Routes keys; the Mac side's venv and
  # sources (scripts/lib/pymcp.sh). The pairing (%LOCALAPPDATA%\RevitMCPPython) is never touched
  local sfx srv cfg st a tmp top p ext mod out ini="$ROOT/tools/pyrevit_ini.py"
  sfx="$(bottle_sfx "$NAME" "$YEAR")"
  { addin_load python-mcp && addin_available; } || { echo "MCP server for Revit (Python) is for Revit 2020 here."; return 1; }
  eula_ok python-mcp || { echo "$ADDIN_NOTICE To accept: add --accept-eula python-mcp (./revit addins $YEAR$sfx --only python-mcp --accept-eula python-mcp)"; return 1; }
  srv="$(pymcp_server_py)"; cfg="$B/$PYREVIT_CONFIG_REL"
  [ -d "$B/$PYREVIT_CLONE_REL" ] && [ -f "$cfg" ] || { echo "install pyRevit first: ./revit addins $YEAR$sfx --only pyrevit"; return 1; }
  st="$(pymcp_server_state "$srv")"
  [ "$st" != foreign ] || { echo "server.py is not the one of pyRevit 4.8.12 ($srv): install pyRevit again (./revit addins $YEAR$sfx --only pyrevit)"; return 1; }
  addin_fetch python-mcp || return 1
  a="$DATA/installers/addins/python-mcp/$PYMCP_COMMIT.tar.gz"; tmp="$RUN_DIR/python-mcp.unpacked"
  rm -rf "$tmp" && mkdir -p "$tmp" && tar xzf "$a" -C "$tmp" || { echo "cannot unpack $a"; return 1; }
  top="$tmp/mcp-server-for-revit-python-$PYMCP_COMMIT"
  for p in "$ROOT"/tools/patches/python-mcp/*.patch; do
    patch -p1 -s --forward -d "$top" -i "$p" >>"$RUN_DIR/pythonmcp-patch.log" 2>&1 \
      || { echo "the MCP extension changed upstream; this project's patches do not fit it ($(basename "$p"))"; return 1; }
  done
  rm -rf "$top/tests" "$top/docs" "$top/images" "$top/.github"
  ext="$B/$PYMCP_EXT_REL"
  mkdir -p "$(dirname "$ext")" && rm -rf "$ext.new" && cp -R "$top" "$ext.new" && rm -rf "$ext" && mv "$ext.new" "$ext" \
    || { echo "cannot write $ext"; return 1; }
  mod="$(dirname "$srv")/revitmacos_serial.py"
  cmp -s "$ROOT/tools/pyrevit48/revitmacos_serial.py" "$mod" \
    || { cp "$ROOT/tools/pyrevit48/revitmacos_serial.py" "$mod.new" && mv -f "$mod.new" "$mod"; } || { echo "cannot write $mod"; return 1; }
  if [ "$st" = original ]; then
    patch --binary -s -o "$srv.new" "$srv" "$ROOT/tools/patches/pyrevit48/server.py.patch" >>"$RUN_DIR/pythonmcp-patch.log" 2>&1 \
      && mv -f "$srv.new" "$srv" || { rm -f "$srv.new"; echo "cannot patch $srv"; return 1; }
  fi
  python3 -I "$ini" set "$cfg" routes enabled true && python3 -I "$ini" set "$cfg" routes host '"127.0.0.1"' \
    && python3 -I "$ini" set "$cfg" routes port 48884 && python3 -I "$ini" set "$cfg" revit-mcp-python.extension disabled false \
    || { echo "cannot write $cfg"; return 1; }
  out="$(pymcp_venv_ensure)" || { echo "$out"; return 1; }
  p="$(pymcp_dir)/src"
  rm -rf "$p.new" && cp -R "$top" "$p.new" && rm -rf "$p" && mv "$p.new" "$p" || { echo "cannot write $p"; return 1; }
  rm -rf "$tmp"
  detail "python-mcp ${PYMCP_COMMIT:0:7}"
}
