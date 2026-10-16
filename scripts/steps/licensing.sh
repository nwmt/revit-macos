# Install steps: Autodesk licensing and sign-in. Licensing runs untouched: the real AdskLicensingService, started
# through our service wrapper because it does not answer Wine's SCM. Sourced by scripts/run-steps.sh.

AL_WIN='C:\Program Files (x86)\Common Files\Autodesk Shared\AdskLicensing'
al_dir() { echo "$B/drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"; }

step_licensing() { # AdskLicensing (BitRock InstallBuilder), switches from pkg.licensing.xml
  local al rc ver f exe="$DIST/x86/Licensing/AdskLicensing-installer.exe"
  [ -f "$exe" ] || exe="$DIST/x86/AdskLicensing/AdskLicensing-installer.exe"   # Setup.ini installers (2020)
  al="$(al_dir)"
  if [ -L "$al/Current" ]; then   # running it again over our Current link fails (LIC-INST-ERROR-240)
    say licensing skip "already installed: $(readlink "$al/Current")"
  else
    install_exe licensing "$exe" --mode unattended --unattendedmodeui none; rc=$?
    cp "$B"/drive_c/users/crossover/AppData/Local/Temp/AdskLicensing-install.log "$RUN_DIR/" 2>/dev/null
    # LICENSING_OK (profile): what the installer returns under Wine when the parts that matter are in place
    accept_codes "$rc" 0 $LICENSING_OK || { echo "the licensing installer returned $rc"; return 1; }
  fi
  # mklink /J under Wine creates an empty "Current<garbage>" folder instead of a junction → a symlink
  for f in "$al"/Current?*; do [ -d "$f" ] && [ ! -L "$f" ] && rmdir "$f"; done
  ver="$(ls "$al" 2>/dev/null | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1)"
  [ -n "$ver" ] || { echo "no AdskLicensing version folder in $al"; return 1; }
  [ -e "$al/Current" ] || ln -sfn "$ver" "$al/Current" || return 1
  # the installer writes version.ini after `servicectl start`, which fails under Wine (1053) → no file, and the
  # licMarkInstall custom action of RVT.msi fails the install (1603). AdskLicensing 9.2 (2020) does not write it either
  [ -f "$al/version.ini" ] || printf '[General]\r\nversion=%s\r\n' "$ver" > "$al/version.ini" || return 1
  [ -f "$al/$ver/helper/AdskLicensingInstHelper.exe" ] || { echo "no helper in $al/$ver"; return 1; }
  detail "AdskLicensing $ver: Current, version.ini"
}

step_svcshim() { # the licensing service (Go, kardianos/service) does not answer SCM under Wine (1053):
  # tools/shims/svcshim registers as the service and runs it as a child in console mode. AdskLicensing 9.2 (Setup.ini
  # installers, 2020) takes its version from its folder's name: started through Current it answers /hubversion with
  # "Current", and RVT.msi's licIsSvcUpgraded fails (exit 100) → svcshim gets the path in the version folder
  local img="\"$AL_WIN\\svcshim.exe\"" ver
  if [ "$INSTALLER" = setupini ]; then
    ver="$(readlink "$(al_dir)/Current")" || { echo "no Current link in $(al_dir): run step licensing first"; return 1; }
    img+=" \"$AL_WIN\\$ver\\AdskLicensingService\\AdskLicensingService.exe\""
  fi
  ensure_shim svcshim || return 1
  cp "$(shim_dir)/svcshim/svcshim.exe" "$(al_dir)/svcshim.exe" || return 1
  mkdir -p "$B/drive_c/ProgramData/Autodesk/AdskLicensingService/Log" || return 1
  # `sc config binPath=` does not change the path under Wine → ImagePath in the registry
  w reg add 'HKLM\System\CurrentControlSet\Services\AdskLicensingService' /v ImagePath /t REG_EXPAND_SZ \
    /d "$img" /f || return 1
  start_service AdskLicensingService || return 1
  detail "AdskLicensingService → $(tr -d '"' <<<"$img"): RUNNING"
}

step_idmgr() { # AdskIdentityManager: Autodesk sign-in in the Mac's browser (2024+), switches from pkg.identity_manager.xml
  install_exe idmgr "$DIST/x64/AdskIdentityManager/AdskIdentityManager-Installer.exe" --mode unattended
  accept_codes $? 0 || return 1
  ls -d "$B/drive_c/Program Files/Autodesk/AdskIdentityManager/"*/ >/dev/null 2>&1 \
    || { echo "AdskIdentityManager is not in Program Files"; return 1; }
  detail "AdskIdentityManager $(ls "$B/drive_c/Program Files/Autodesk/AdskIdentityManager" | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1)"
}

step_adsso() { # AdSSO: Autodesk sign-in in Revit's own window (QtWebEngine), 2020 and 2023; from pkg.adsso.xml
  msi adsso "$(win "$DIST")\\x64\\AdSSO\\AdSSO.msi"; accept_codes $? 0 194 || return 1
  detail "AdSSO.msi"
}

step_ssoenv() { # AdSSO's sign-in window (QtWebEngine) loads forever under Wine with GPU rendering and works without it.
  # For every process in the bottle: AdSSO starts the licensing agent, not our command
  bottle_env 'QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu --disable-gpu-compositing' \
    -QTWEBENGINE_REMOTE_DEBUGGING -QT_LOGGING_RULES || return 1
  detail "QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu --disable-gpu-compositing"
}

step_register() { # register the product with AdskLicensing as Setup.exe does. ODIS installers: RVT.msi's own
  # licRegister is skipped (CLM_SKIP_REGISTER, step rvt) because in AdskLicensing 15 it looks for FNP_Act_Installer.dll,
  # which is gone. The Setup.ini installer (2020): RVT.msi registers too, and this registers again, as Setup.exe does
  local pit="C:\\ProgramData\\Autodesk\\Revit\\Revit $YEAR\\Setup\\RevitConfig.pit" h="$AL_WIN\\Current\\helper\\AdskLicensingInstHelper.exe"
  local src="$DIST/x64/RVT/RevitConfig.pit"
  [ -f "$src" ] || src="$DIST/Setup/RevitConfig.pit"   # Setup.ini installers (2020)
  mkdir -p "$B/drive_c/ProgramData/Autodesk/Revit/Revit $YEAR/Setup" || return 1
  cp "$src" "$B/drive_c/ProgramData/Autodesk/Revit/Revit $YEAR/Setup/" || return 1
  w "$h" register --pk "$PRODKEY" --pv "$YEAR.0.0.F" --el US --lm USER --cf "$pit" || return 1
  w "$h" list | tr -d '\r' | head -20
  detail "$PRODKEY $YEAR.0.0.F USER"
}
