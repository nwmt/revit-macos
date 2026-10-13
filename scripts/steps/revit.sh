# Install steps: Revit itself, its ODIS packages, Shared Components, Revit.ini, Generative Design, Dynamo settings.
# Sourced by scripts/run-steps.sh; see the step contract there.

step_rvt() { # RVT.msi: LaunchCondition "Installed or ADSK_SETUP_EXE or ADSK_ODIS_SETUP"; properties from pkg.RVT.xml.
  # licIsSvcUpgraded runs `InstHelper upgrade isUpgraded` from the AdskLicensing version folder and fails the install
  # (1603) unless the licensing service answers: we run the same first, so a silent service stops here with the
  # helper's output in the log. licRegister would look for FNP_Act_Installer.dll, gone in AdskLicensing 15 →
  # CLM_SKIP_REGISTER=1 and the register step. REVITLANGUAGE is the three-letter code (RVT.msi Property: ENU).
  # An update that is an MSP patch of RVT.msi (2024: x64/RVTSP*.msp, pkg.RVTSP.xml) goes in with PATCH=.
  local ver x f patch=() rc
  [ "$INSTALLER" = odis ] || { echo "step rvt: the $INSTALLER installer is handled by d6 until stage 2"; return 1; }
  ver="$(readlink "$(al_dir)/Current")"; [ -n "$ver" ] || ver=Current
  w "$AL_WIN\\$ver\\helper\\AdskLicensingInstHelper.exe" upgrade isUpgraded \
    || { echo "the Autodesk licensing service does not answer, so RVT.msi would fail"; return 1; }
  x="$(grep -l 'InstallFile type="MSP"' "$DIST"/x64/pkg.*.xml 2>/dev/null | head -1)"
  if [ -n "$x" ]; then
    f="$(grep -o 'InstallFile type="MSP"[^>]* file="[^"]*"' "$x" | sed 's/.* file="//; s/"$//')"
    [ -f "$DIST/$f" ] && patch=("PATCH=$(win "$DIST/$f")")
  fi
  msi rvt "$(win "$DIST")\\x64\\RVT\\RVT.msi" "TRANSFORMS=:$LANG_UI.mst;:all.mst" \
    ADSK_SETUP_EXE=1 ADSK_EULA_STATUS=#1 "ADLM_PRODKEY=$PRODKEY" ADLM_EULA_COUNTRY=US \
    REVITLANGUAGE=ENU CLM_SKIP_REGISTER=1 "INSTALLDIR=C:\\Program Files\\Autodesk\\Revit $YEAR" \
    ${patch[@]+"${patch[@]}"}; rc=$?
  accept_codes "$rc" 0 194 || { echo "RVT.msi returned $rc: $RUN_DIR/rvt.msi.log"; return 1; }
  # no Revit.exe check here: since 2025 it comes from an ADIX package (step pkgs); install.sh checks it at the end
  detail "RVT.msi${patch[0]:+ + ${patch[0]##*\\}}$([ -f "$RD/Revit.exe" ] && echo ': Revit.exe in place')"
}

step_pkgs() { # product packages from manifest/app.RVT.xml except RVT (step rvt): ADIX through tools/adix.py, MSI
  # through msiexec. The list is the profile's PKGS or ODIS_PKGS ("A|B"): the core without Dynamo, Twinmotion and other
  # languages. Generative Design is needed: its stub .addin ships in RCPRVT, and without the MSI Revit says
  # "GenerativeDesignForRevitApplication does not inherit from IExternalApplication"
  local names pname ptype pfile pparams tag t0 r rc=0 n extra
  IFS='|' read -r -a names <<< "${ODIS_PKGS:-$PKGS}"
  python3 -I "$ROOT/tools/odis.py" get "$DIST" "${names[@]}" > "$RUN_DIR/pkgs.tsv" || return 1
  # tab is whitespace to `read`, and empty columns would collapse: split on \037 instead
  while IFS=$'\037' read -r pname _ ptype pfile pparams; do
    tag="$(echo "$pname" | tr -c 'A-Za-z0-9_\n' '_')"; t0=$SECONDS; r=0
    case "$ptype" in
      ADIX)
        n="$(python3 -I "$ROOT/tools/adix.py" files "$DIST/$pfile" "$B/drive_c")" || r=1
        python3 -I "$ROOT/tools/adix.py" reg "$DIST/$pfile" "$B/drive_c/$tag.reg" || r=1
        if [ -f "$B/drive_c/$tag.reg" ]; then
          w regedit /s "C:\\$tag.reg" || r=1
          mv "$B/drive_c/$tag.reg" "$RUN_DIR/"
        fi
        say "$tag" "$r" "ADIX $pfile: ${n:-?} files$([ -f "$RUN_DIR/$tag.reg" ] && echo ' + registry') ($((SECONDS - t0)) s)" ;;
      MSI)
        read -r -a extra <<< "$pparams"
        msi "$tag" "$(win "$DIST/$pfile")" ADSK_SETUP_EXE=1 ${extra[@]+"${extra[@]}"}; r=$?
        say "$tag" "$r" "$(win "$DIST/$pfile") ($((SECONDS - t0)) s)"
        accept_codes "$r" 0 194 && r=0
        # Steel Connections (2025–2027): DIRCA_INSTALLDIR builds the folder from REVIT-05\InstallRoot (RVT.msi sets it to
        # Revit's own folder here) + "Revit <year>" → "…\Revit 2025Revit 2025\"; INSTALLDIR does not override it. Its
        # language resources belong in Revit's AddIns\SteelConnections (the add-in itself is ADIX): move them
        if [ "$pname" = RVTCPSTLCON ] && [ -d "${RD}Revit $YEAR" ]; then
          ditto "${RD}Revit $YEAR" "$RD" && rm -rf "${RD}Revit $YEAR" || r=1
          say "$tag" "$r" "moved its files from \"Revit ${YEAR}Revit $YEAR\" into \"Revit $YEAR\""
        fi ;;
      *) say "$tag" skip "type $ptype ($pfile): not supported" ;;
    esac
    [ "$r" = 0 ] || rc=1
  done < <(tr '\t' '\037' < "$RUN_DIR/pkgs.tsv")
  detail "$(wc -l < "$RUN_DIR/pkgs.tsv" | tr -d ' ') packages"
  return $rc
}

step_asc() { # Autodesk Shared Components (pkg ASC, type EXE): an ODIS bundle itself — 7z subpackages into
  # %COMMONPROGRAMFILES%\Autodesk Shared\Components\<year>\<version> + its registry tool (postInstall). Without it
  # Revit 2026 fails at startup: "Autodesk Shared Components bundle is missing" (ASC status 6)
  local ae ax ver base bw n=0 z tool pkgs
  pkgs="$(python3 -I "$ROOT/tools/odis.py" list "$DIST")" || return 1   # a manifest it cannot read is a failure, not a skip
  cut -f1 <<<"$pkgs" | grep -qx ASC || { skip "no ASC package"; return 0; }
  ae="$DIST/$(python3 -I "$ROOT/tools/odis.py" get "$DIST" ASC | cut -f4)"; ax="$(dirname "$ae")/x"   # 2026: x64/ASC, 2027: x64/ASC2
  [ -f "$ax/setup.xml" ] || 7zz x -y -o"$ax" "$ae" || return 1
  ver="$(grep -oE '<BuildNumber[^>]*>[0-9.]+' "$ax/setup.xml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [ -n "$ver" ] || { echo "no BuildNumber in $ax/setup.xml"; return 1; }
  base="Program Files/Common Files/Autodesk Shared/Components/$YEAR"; mkdir -p "$B/drive_c/$base/$ver" || return 1
  for z in "$ax"/*/*.7z; do 7zz x -y -o"$B/drive_c/$base/$ver" "$z" || return 1; n=$((n + 1)); done
  bw="C:\\${base//\//\\}"
  tool=ASCRegistryTool.exe; [ -f "$B/drive_c/$base/$ver/$tool" ] || tool=CompRegistryTool.exe   # ASC 2.0 (2027): new name
  w "$bw\\$ver\\$tool" --installpath "$bw" --version "$ver" --releaseyear "$YEAR" --registry set || return 1
  w reg query "HKLM\\SOFTWARE\\Autodesk\\SharedComponents\\$YEAR"
  detail "$n subpackages → $bw\\$ver; $tool --registry set"
}

step_revitini() { # Revit takes template and library paths from [Directories<Select>] in Revit.ini; 2027 wrote
  # [Language] Select=en-US, which has no such section → empty template lists: Select=ENU. More keys from the
  # profile (RealDWG path in 2024, 2025). THEME=1: anti-aliasing off (smoother under Wine; DXMT draws a black view with
  # it) and Revit's light or dark theme from macOS at install time, or REVIT_THEME=dark|light. In the seed for new
  # users (ProgramData) and in the user profile; Revit must be closed
  local keys=(${REVITINI[@]+"${REVITINI[@]}"}) theme="" t f n=0
  if [ "$THEME" = 1 ]; then
    theme="${REVIT_THEME:-$(defaults read -g AppleInterfaceStyle 2>/dev/null | grep -qi dark && echo dark || echo light)}"
    t=1; [ "$theme" = dark ] && t=0
    keys+=(Graphics.Antialiasing=0 Graphics.AntialiasingOptions=1 AppFrame.Theme=$t AppFrame.FollowSystemColorTheme=0 Colors.CanvasTheme=$t)
  fi
  [ ${#keys[@]} -gt 0 ] || { skip "no Revit.ini keys for Revit $YEAR"; return 0; }
  for f in "$B/drive_c/ProgramData/Autodesk/RVT $YEAR/UserDataCache/Revit.ini" \
           "$B/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit $YEAR/Revit.ini"; do
    [ -f "$f" ] || continue
    python3 -I "$ROOT/tools/revitini.py" "$f" "${keys[@]}" || return 1
    n=$((n + 1))
  done
  [ $n -gt 0 ] || { skip "no Revit.ini yet"; return 0; }
  detail "${keys[*]}${theme:+ ($theme)}: $n file(s)"
}

step_gdoff() { # Generative Design: "GenerativeDesignForRevitApplication does not inherit from IExternalApplication"
  # even with its MSI. Interactively a dialog; in journal playback (RFO benchmark) an "unrecoverable error" at start.
  # Turned off reversibly (.addin.off); root cause not investigated
  local a="$RD/AddIns/GenerativeDesignForRevit/GenerativeDesignForRevit.addin"
  [ -f "$a" ] || [ -f "$a.off" ] || { skip "no Generative Design add-in"; return 0; }
  [ ! -f "$a" ] || mv "$a" "$a.off" || return 1
  detail "GenerativeDesignForRevit.addin → .addin.off"
}

step_dynamo() { # Dynamo's 3D preview breaks under D3DMetal: hardware acceleration and the background preview off
  # (tools/dynamo_settings.py). Dynamo writes the file on exit: run with Revit closed
  local ds
  [ -n "$DYNAMO" ] || { skip "no Dynamo settings for Revit $YEAR"; return 0; }
  ds="$B/drive_c/users/crossover/AppData/Roaming/Dynamo/Dynamo Revit/$DYNAMO/DynamoSettings.xml"
  mkdir -p "$(dirname "$ds")" || return 1
  python3 -I "$ROOT/tools/dynamo_settings.py" "$ds" || return 1
  detail "Dynamo $DYNAMO: UseHardwareAcceleration=false, IsBackgroundPreviewActive=false"
}
