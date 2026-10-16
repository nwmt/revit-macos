# Install steps: Windows runtimes from Revit's installer (VC++, .NET), core fonts, WebView2.
# Sourced by scripts/run-steps.sh; see the step contract there.

VC14_DLLS=(api-ms-win-crt-private-l1-1-0 api-ms-win-crt-conio-l1-1-0 api-ms-win-crt-heap-l1-1-0
  api-ms-win-crt-locale-l1-1-0 api-ms-win-crt-math-l1-1-0 api-ms-win-crt-runtime-l1-1-0
  api-ms-win-crt-stdio-l1-1-0 api-ms-win-crt-time-l1-1-0 atl140 concrt140 msvcp140 msvcp140_1
  msvcp140_2 msvcp140_atomic_wait ucrtbase vcamp140 vcomp140 vccorlib140 vcruntime140 vcruntime140_1)

vc_install() { install_exe "$@"; accept_codes $? 0 194 102; }   # 0, 3010 reboot needed, 1638 a newer one is there

step_vc() { # Visual C++ runtimes from the installer, oldest first. The branch follows the installer's files, not the
  # year, so a new version with a familiar layout needs no change here
  local rc=0 x f p v arch args
  override "${VC14_DLLS[@]}" || return 1   # DLL overrides as in the winetricks vcrun recipes
  if [ -f "$DIST/3rdParty/x64/VCRedist/2022/VC_redist.x64.exe" ]; then
    # VC++ 2022 (v14) supersedes 2019, which ODIS also installs; 2019 after 2022 would return 1638
    vc_install vc22x86 "$DIST/3rdParty/x86/VCRedist/2022/VC_redist.x86.exe" /install /quiet /norestart || rc=1
    vc_install vc22x64 "$DIST/3rdParty/x64/VCRedist/2022/VC_redist.x64.exe" /install /quiet /norestart || rc=1
    detail "VC++ 2022 x86 and x64"
  elif ls "$DIST"/3rdParty/x86/VCRedist/*/pkg.*.xml "$DIST"/3rdParty/x64/VCRedist/*/pkg.*.xml >/dev/null 2>&1; then
    # 2023: 2012, 2013, (2017 x86), 2019; 2024: 2012, 2013, 2019, 2022 (as vcredist_x64.exe) — every one the
    # installer ships, oldest first, switches from its pkg.*.xml
    for x in "$DIST"/3rdParty/x86/VCRedist/*/pkg.*.xml "$DIST"/3rdParty/x64/VCRedist/*/pkg.*.xml; do
      [ -f "$x" ] || continue
      f="$(grep -o 'file="[^"]*"' "$x" | head -1 | cut -d'"' -f2)"
      p="$(grep -o 'installParams="[^"]*"' "$x" | head -1 | cut -d'"' -f2)"
      read -r -a args <<< "${p%% /l *}"   # drop "/l %temp%\…log": %temp% is not expanded here
      v="$(basename "$(dirname "$x")")"; arch="${x#"$DIST"/3rdParty/}"; arch="${arch%%/*}"
      vc_install "vc${v:2:2}$arch" "$DIST/$f" ${args[@]+"${args[@]}"} || rc=1
    done
    detail "VC++ runtimes from the installer's pkg.*.xml"
  elif [ -f "$DIST/3rdParty/x64/VCRedist/2010SP1/vcredist_x64.exe" ]; then
    # Setup.ini installers (2020): 2010 SP1, 2012, 2013, 2017, each after its DLL overrides; 2015 is the same v14
    # runtime as 2017 and would return 1638 after it
    override msvcp100 msvcr100 vcomp100 atl100 || return 1
    vc_install vc10x86 "$DIST/3rdParty/x86/VCRedist/2010SP1/vcredist_x86.exe" /q /norestart || rc=1
    vc_install vc10x64 "$DIST/3rdParty/x64/VCRedist/2010SP1/vcredist_x64.exe" /q /norestart || rc=1
    override atl110 msvcp110 msvcr110 vcomp110 || return 1
    vc_install vc12x86 "$DIST/3rdParty/x86/VCRedist/2012/vcredist_x86.exe" /q /norestart || rc=1
    vc_install vc12x64 "$DIST/3rdParty/x64/VCRedist/2012/vcredist_x64.exe" /q /norestart || rc=1
    override atl120 msvcp120 msvcr120 vcomp120 || return 1
    vc_install vc13x86 "$DIST/3rdParty/x86/VCRedist/2013/vcredist_x86.exe" /q /norestart || rc=1
    vc_install vc13x64 "$DIST/3rdParty/x64/VCRedist/2013/vcredist_x64.exe" /q /norestart || rc=1
    vc_install vc17x86 "$DIST/3rdParty/x86/VCRedist/2017/VC_redist.x86.exe" /install /quiet /norestart || rc=1
    vc_install vc17x64 "$DIST/3rdParty/x64/VCRedist/2017/VC_redist.x64.exe" /install /quiet /norestart || rc=1
    detail "VC++ 2010 SP1, 2012, 2013, 2017 x86 and x64"
  else
    echo "no VC++ runtimes in $DIST/3rdParty (VCRedist/2022, pkg.*.xml or VCRedist/2010SP1)"; return 1
  fi
  return $rc
}

step_fonts() { # core fonts and MSXML 6 through winetricks
  # the app keeps winetricks' downloads with its other caches ("clear cache" in the app reaches them)
  [ "${REVIT_BUNDLED:-0}" = 1 ] && export W_CACHE="$DATA/cache/winetricks"
  WINE="$ROOT/scripts/lib/cxwine" WINESERVER="$CX/bin/wineserver" CX_BOTTLE="$NAME" WINEPREFIX="$B" \
    winetricks -q --unattended corefonts msxml6 7>&- 9>&- || return 1
  detail "winetricks corefonts msxml6"
}

step_netfx() { # .NET Framework from Revit's installer on top of a real 4.0 (the winetricks dotnet4x recipe): 4.7 for
  # DOTNET=netfx47 (Revit 2020 crashes on 4.7.2 and 4.8 under Wine), 4.8 for netfx48
  local net40="$DATA/installers/redist/dotNetFx40_Full_x86_x64.exe" netx ver min rc rel
  case "$DOTNET" in
    netfx47) ver=4.7; min=460798; netx="$DIST/3rdParty/NET/47/wcu/dotNetFramework/dotNetFx47_Full_x86_x64.exe" ;;
    netfx48) ver=4.8; min=528040; netx="$DIST/3rdParty/dotNetFramework/48/dotNetFx48_Full_x86_x64.exe" ;;
    *) skip "Revit $YEAR runs on .NET, not .NET Framework"; return 0 ;;
  esac
  [ -f "$net40" ] || { echo "no $net40: run ./scripts/get-redist.sh $YEAR"; return 1; }
  [ -f "$netx" ] || { echo "no $netx"; return 1; }
  # the installers run as Windows XP x64 and 7; whatever happens there, the bottle goes back to Windows 10. Ctrl-C lets
  # them finish: the step runs in its own subshell, so the runner still stops after it
  trap '' INT TERM HUP
  netfx_as_old_windows "$net40" "$netx" "$ver"; rc=$?
  w winecfg -v win10 || return 1
  [ $rc = 0 ] || return 1
  # the MSI asks for a reboot (pending file renames). Its code is only logged: unchecked since 2023 and 2024 installed
  # fine; the Release check below is what counts
  w wineboot -r || echo "wineboot -r returned $?"
  # the installers' exit codes say little under Wine: check what got installed
  rel="$(w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>/dev/null | tr -d '\r' | awk '/Release/{print $3}')"
  [ $((rel)) -ge $min ] || { echo ".NET Framework $ver is not installed (Release=$((rel)))"; return 1; }
  detail "Release=$((rel)) ($min+ = $ver)"
}

netfx_as_old_windows() { # $1 = the 4.0 installer, $2 = the 4.x one, $3 = its version (4.7 | 4.8). Leaves the bottle
  # as Windows 7 or XP x64: step_netfx puts Windows 10 back
  local k
  # Wine's own mscoree leaves fake NDP keys and stub DLLs: the real installers would think .NET is there
  for k in 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' 'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4'; do
    w reg delete "$k" /f
  done
  rm -f "$B/drive_c/windows/system32/mscoree.dll" "$B/drive_c/windows/syswow64/mscoree.dll"
  # 4.0 as Windows XP x64 installs the real mscoree.dll, which 4.5 and later lack
  w winecfg -v winxp64 || return 1
  WINEDLLOVERRIDES="fusion=b" run_exe dotNetFx40 "$1" /q '/c:install.exe /q'; echo "4.0 installer exit=$?"
  w reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f || return 1
  for k in 'HKLM\Software\Microsoft\.NETFramework' 'HKLM\Software\Wow6432Node\.NETFramework'; do
    w reg add "$k" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f || return 1
  done
  # on Windows 10 1703+ the 4.7/4.8 installers say "already installed": install as Windows 7
  w winecfg -v win7 || return 1
  WINEDLLOVERRIDES="fusion=b" run_exe "dotNetFx${3/./}" "$2" /q /norestart /log 'C:\netfx-setup'; echo "$3 installer exit=$?"
  # the installer's own logs: removed from the bottle only once they are in the run folder
  cp "$B"/drive_c/netfx-setup* "$RUN_DIR/" 2>/dev/null && rm -f "$B"/drive_c/netfx-setup*
  return 0
}

step_dotnet() { # .NET Desktop + ASP.NET Core runtimes from the installer, every one it ships, oldest first: an update
  # laid over the base adds a newer one (2026.5: 10.0 next to 8.0). Switches from pkg.dotnet*.xml / pkg.aspnet*.xml
  local rc=0 x desk=() asp=()
  case "$DOTNET" in net[0-9]*) ;; *) skip "Revit $YEAR runs on .NET Framework"; return 0 ;; esac
  while IFS= read -r x; do desk+=("$x"); done < <(ls "$DIST"/3rdParty/x64/dotNet/*/windowsdesktop-runtime-*.exe 2>/dev/null | sort -V)
  while IFS= read -r x; do asp+=("$x"); done < <(ls "$DIST"/3rdParty/x64/aspNetCore/*/aspnetcore-runtime-*.exe 2>/dev/null | sort -V)
  [ ${#desk[@]} -gt 0 ] || { echo "no .NET Desktop runtime in $DIST/3rdParty/x64/dotNet"; return 1; }
  for x in "${desk[@]}"; do
    install_exe "netdesk$(basename "$(dirname "$x")")" "$x" /install /quiet /norestart; accept_codes $? 0 194 102 || rc=1
  done
  for x in ${asp[@]+"${asp[@]}"}; do
    install_exe "netasp$(basename "$(dirname "$x")")" "$x" /q /norestart; accept_codes $? 0 194 102 || rc=1
  done
  detail "$(ls "$B/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" 2>/dev/null | tr '\n' ' ')"
  return $rc
}

step_webview2() { # Edge WebView2 for the sign-in window and web panels ("Web browser runtime could not be initialized"
  # without it). The installer ships runtime 103 (2022), too old for Revit's SDK (1.0.2478.35, runtime ~124+): Revit
  # gets E_NOINTERFACE, the start screen and Manage Links stay blank. A fresh Evergreen Standalone from
  # installers/redist/webview2 (scripts/get-redist.sh) if there is one, else the installer's
  local wv="$DATA/installers/redist/webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  [ -f "$wv" ] || wv="$DIST/3rdParty/x64/WebView2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
  install_exe webview2 "$wv" /silent /install; accept_codes $? 0 || return 1
  detail "$(ls "$B/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ')"
}
