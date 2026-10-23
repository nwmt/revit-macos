# The add-in catalog: one file per add-in in scripts/addins/<id>.sh (see scripts/addins/pyrevit.sh for the fields).
# Source after common.sh. ./revit addins --only and the app take the add-ins from here; the steps that install them
# stay in scripts/steps/addins.sh and scripts/steps/fixes.sh.
. "$ROOT/scripts/lib/mcp.sh"   # the Revit MCP Server's variants (scripts/addins/revitmcp*.sh)
ADDIN_IDS=(); for _f in "$ROOT"/scripts/addins/*.sh; do [ -f "$_f" ] && ADDIN_IDS+=("$(basename "$_f" .sh)"); done; unset _f

addin_dirs() { # the user's Addins folder, then the two all-users ones (the second since 2027); uses $B and $YEAR
  echo "$B/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Addins/$YEAR"
  echo "$B/drive_c/ProgramData/Autodesk/Revit/Addins/$YEAR"
  echo "$B/drive_c/Program Files/Autodesk/Revit/Addins/$YEAR"
}

addin_load() { # $1 = id: its fields and functions; 1 = no such add-in
  ADDIN_NAME=""; ADDIN_ABOUT=""; ADDIN_TESTED=(); ADDIN_EULA=""; ADDIN_AFTER=(); ADDIN_TOOL=""; ADDIN_STEP=""
  addin_files() { :; }; addin_is_installed() { return 1; }
  in_list "$1" ${ADDIN_IDS[@]+"${ADDIN_IDS[@]}"} || return 1
  . "$ROOT/scripts/addins/$1.sh"
}
addin_available() { [ -n "$(addin_files "$YEAR")" ]; }   # after addin_load: something to install for $YEAR
eula_ok() { case ",${REVIT_ACCEPT_EULA:-}," in *",$1,"*) return 0 ;; esac; return 1; }

addin_fetch() { # $1 = id (loaded): the auto files of $YEAR that are not there yet, from their URL, sha256 checked
  local s f u h p
  while IFS=$'\t' read -r s f u h; do
    p="$DATA/installers/addins/$f"
    [ "$s" = auto ] && [ ! -f "$p" ] || continue
    mkdir -p "$(dirname "$p")" || return 1
    echo ">> $(basename "$p") from $u"
    curl -fL --retry 3 -C - -o "$p.part" "$u" || { result_set reason download; echo "download failed; run again to resume"; return 1; }
    echo "$h  $p.part" | shasum -a 256 -c --quiet - || { rm -f "$p.part"; echo "checksum mismatch, download removed"; return 1; }
    mv "$p.part" "$p"
  done < <(addin_files "$YEAR")
}

addin_plan() { # ids… → the run-steps list: each add-in's step, then the after-steps they need (trust, wpfsw), check
  local id a want_trust=0 want_wpf=0 out=""
  for id in "$@"; do
    addin_load "$id"; out+="$ADDIN_STEP "
    for a in ${ADDIN_AFTER[@]+"${ADDIN_AFTER[@]}"}; do
      case "$a" in trust) want_trust=1 ;; wpfsw) [ "${ADDIN_WPF_SW:-0}" = 1 ] && want_wpf=1 ;; esac
    done
  done
  [ $want_trust = 0 ] || out+="trust "; [ $want_wpf = 0 ] || out+="wpfsw "
  echo "${out}check"
}
