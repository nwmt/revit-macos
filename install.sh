#!/usr/bin/env bash
# One-command install of Autodesk Revit into a CrossOver bottle. Users run it as ./revit install <year>.
# Usage: ./install.sh <year> [bottle]
#   ./install.sh 2026             → bottle rvt2026-a, app ~/Applications/Revit 2026 (rvt2026-a).app
#   INSTALL_DRYRUN=1 ./install.sh 2026   checks and prints the plan, changes nothing (./revit check 2026)
#   CX_RECREATE=1 ./install.sh 2026 [bottle]   deletes and rebuilds an existing bottle (./revit rebuild 2026)
# Supported: the years with a profile in scripts/profiles/. Logs: logs/<bottle>/<time>-install/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; . "$ROOT/scripts/lib/common.sh"
YEAR_ARG="${1:-}"; BOTTLE="${2:-}"
if [ -z "$YEAR_ARG" ]; then sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 2
elif ! load_profile "$YEAR_ARG"; then
  echo "Revit $YEAR_ARG is not supported yet." >&2
  echo "Working versions: $(printf '%s, ' "${REVIT_SUPPORTED[@]}" | sed 's/, $//'). See README.md." >&2; exit 1
fi
BOTTLE="${BOTTLE:-$(revit_bottle_default "$YEAR")}"
revit_bottle_name_ok "$BOTTLE" \
  || { echo "Bottle name may contain only letters, digits, - and _, and cannot be \"default\": \"$BOTTLE\"" >&2; exit 1; }
SFX="$(bottle_sfx "$BOTTLE" "$YEAR")"; B="$(bottle_path "$BOTTLE")"

# ---- preflight: report every problem at once, with the fix ----
missing=0
need() { echo "  ✗ $1"; echo "      fix: $2"; missing=1; }
warn() { echo "  ! $1"; echo "      $2"; }
echo "Checking requirements for Revit $YEAR (bottle $BOTTLE)…"
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
  need "Apple Silicon Mac required" "this setup is tested on M-series Macs only"
elif [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
  need "this Terminal runs under Rosetta" "quit Terminal, turn off \"Open using Rosetta\" in its Get Info window, and run again"
fi
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || need "Rosetta 2 is not installed" "softwareupdate --install-rosetta --agree-to-license"
[ -x "$CX/bin/cxbottle" ] || need "CrossOver not found in /Applications" "install it from https://www.codeweavers.com/crossover (trial available)"
for t in 7zz:sevenzip winetricks:winetricks cabextract:cabextract gs:ghostscript python3:python3; do
  command -v "${t%%:*}" >/dev/null || need "${t%%:*} not found" "brew install ${t#*:}"
done
SRC="$(revit_installers "$YEAR")"; DST="$(revit_extracted "$YEAR")"
# Autodesk Account now gives only "Create Installer": scripts/get-revit.sh downloads the full installer it points to
GET=""; [ ! -d "$DST" ] && [ -n "$(find -H "$SRC" -maxdepth 1 -type f -iname "Create_Installer_RVT_${YEAR}_*.exe" 2>/dev/null | head -1)" ] && GET=1
if [ ! -d "$DST" ] && [ -z "$(find -H "$SRC" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.7z' -o -iname '*.zip' -o -iname '*.iso' \) 2>/dev/null | head -1)" ]; then
  need "no Revit $YEAR installer in installers/revit$YEAR/" "download it from your Autodesk Account, see installers/README.md"
fi
part1=$(find -H "$SRC" -maxdepth 2 -type f -iname '*_001_0*.sfx.exe' 2>/dev/null | head -1)
if [ ! -d "$DST" ] && [ -z "$GET" ] && [ -n "$part1" ]; then # multi-part download (2020, 2023): every part 001…NNN
  total=$(basename "$part1" | sed -E 's/.*_001_0*([0-9]+)\.sfx\.exe$/\1/'); stem="${part1%_001_*}"; tot3=$(printf '%03d' "$total")
  gone=""; for p in $(seq -f '%03g' 1 "$total"); do [ -f "${stem}_${p}_${tot3}.sfx.exe" ] || gone+=" $p"; done
  [ -z "$gone" ] || need "installer parts missing in installers/revit$YEAR/:$gone (of $tot3)" "download all parts from your Autodesk Account"
fi
if [ ! -d "$DST" ] && [ -z "$GET" ] && [ -z "$part1" ] && [ -z "$(find -H "$SRC" -maxdepth 2 -type f -iname '*.7z' 2>/dev/null | head -1)" ]; then
  need "no .7z payload in installers/revit$YEAR/ (the small .exe alone is only the downloader)" \
       "download both files of the Autodesk download, see versions/$YEAR.md"
fi
[ -f "$DATA/installers/redist/win7sp1/x64/msls31.dll" ] || need "installers/redist/win7sp1/x64/msls31.dll missing" \
  "copy C:\\Windows\\System32\\msls31.dll from a licensed Windows 7/10 x64 PC, see installers/README.md"
if [ -d "$B" ] && [ "${CX_RECREATE:-0}" != 1 ]; then
  need "bottle $BOTTLE already exists" "pick another name (./revit install $YEAR rvt$YEAR-b) or rebuild it: ./revit rebuild $YEAR$SFX"
fi
free=$(free_gb)
if [ -n "$GET" ]; then [ "$free" -ge 55 ] || warn "only $free GB free" "an install that downloads Revit needs up to ~55 GB (download, extracted files, bottle)"
else [ "$free" -ge 40 ] || warn "only $free GB free" "an install needs up to ~45 GB (installer, extracted files, bottle)"; fi
H="$(hostname)"
grep -qE "[[:space:]]$H([[:space:]]|\$)" /etc/hosts \
  || warn "this Mac's name is not in /etc/hosts — Revit waits ~5 s on every lookup of it" \
          "sudo sh -c 'printf \"127.0.0.1\\t$H\\n::1\\t$H\\n\" >> /etc/hosts'"
[ $missing -eq 1 ] || echo "  ✓ ready"

# ---- plan: actions, each a script with its arguments ----
PLAN=(shims); [ -n "$GET" ] && PLAN+=(revit); PLAN+=(redist unpack bottle steps apps)
action_argv() { # $1 = action → A=(script, arguments), the script relative to the repo
  case "$1" in
    shims)      A=(scripts/get-shims.sh) ;;
    revit)      A=(scripts/get-revit.sh "$YEAR") ;;
    redist)     A=(scripts/get-redist.sh "$YEAR") ;;
    unpack)     A=(scripts/unpack-revit.sh "$YEAR") ;;
    bottle)     A=(scripts/new-bottle.sh "$YEAR" "$BOTTLE") ;;
    steps)      A=(scripts/run-steps.sh "$YEAR" "$BOTTLE") ;;
    apps)       A=(scripts/make-apps.sh "$YEAR" "$BOTTLE") ;;
  esac
}
echo; echo "Plan:"; i=1
for a in "${PLAN[@]}"; do action_argv "$a"; echo "  $i. ${A[*]}"; i=$((i + 1)); done
echo "Steps: ${STEPS[*]}"
[ $missing -eq 0 ] || { echo; echo "Fix the items marked ✗ and run ./revit install $YEAR$SFX again."; exit 1; }
[ "${INSTALL_DRYRUN:-0}" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }

# ---- run ----
lock_take "install.sh $YEAR $BOTTLE"
bottle_guard allow_missing "$YEAR" "$BOTTLE"
[ ! -d "$B" ] || [ "${CX_RECREATE:-0}" = 1 ] || die "Bottle $BOTTLE already exists. To rebuild it: ./revit rebuild $YEAR$SFX"
RUN_DIR="$(run_dir_new "$BOTTLE" install)" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
export RUN_DIR
echo; echo "Logs: $(tilde "$RUN_DIR")"
t0=$SECONDS; i=1
for a in "${PLAN[@]}"; do
  stop_check
  action_argv "$a"; echo; echo "==> [$i/${#PLAN[@]}] ${A[*]}"; t=$SECONDS
  # the action's output also goes to action-<name>.log (new-bottle.sh and run-steps.sh write their own logs as well)
  run_child --log "$RUN_DIR/action-$a.log" "$ROOT/${A[0]}" "${A[@]:1}"; rc=$?
  printf '   %-10s exit=%-5s %s\n' "$a" "$rc" "${A[*]} ($((SECONDS - t)) s; action-$a.log)" >> "$RUN_DIR/summary.txt"
  stop_check
  # a failed fix after Revit.exe is in place: go on, the list comes at the end; anything else stops the install,
  # also a runner that stopped or failed without naming a failed step in failed.txt
  if [ $rc != 0 ] && ! { [ "$a" = steps ] && [ -f "$(revit_dir_unix "$B" "$YEAR")/Revit.exe" ] && [ -s "$RUN_DIR/failed.txt" ]; }; then
    echo; echo "Step failed: ${A[*]}" >&2
    last="$(tail -1 "$RUN_DIR/failed.txt" 2>/dev/null)"; log="$RUN_DIR/action-$a.log"
    [ -n "$last" ] && [ -f "$RUN_DIR/$last.log" ] && log="$RUN_DIR/$last.log"   # a failed step: its own log
    echo "Last log: $(tilde "$log")" >&2; tail -15 "$log" 2>/dev/null | sed 's/^/  | /' >&2
    again="./revit install $YEAR$SFX"; [ -d "$B" ] && again="./revit rebuild $YEAR$SFX"
    echo "See docs/troubleshooting.md. To start over: $again" >&2
    exit 1
  fi
  i=$((i + 1))
done

# installers report errors in their own way; check the result instead of trusting exit codes
if [ ! -f "$(revit_dir_unix "$B" "$YEAR")/Revit.exe" ]; then
  echo; echo "Install finished, but Revit.exe is not in the bottle. Logs: ./revit logs $YEAR$SFX. To start over: ./revit rebuild $YEAR$SFX" >&2
  exit 1
fi
problems=""
[ ! -s "$RUN_DIR/failed.txt" ] || problems="$(sed 's/^/  /' "$RUN_DIR/failed.txt")"
if [ -n "$problems" ]; then
  echo; echo "Some steps failed (Revit may still work; details in $(tilde "$RUN_DIR")):"; printf '%s\n' "$problems"
  echo "To try them again: ./revit rebuild $YEAR$SFX"
fi
echo
echo "Done in $(((SECONDS - t0) / 60)) min."
echo "Start Revit from ~/Applications/Revit $YEAR ($BOTTLE).app"
[ -d "$HOME/Applications/Revit Viewer $YEAR ($BOTTLE).app" ] && echo "Revit Viewer (free, no license needed): ~/Applications/Revit Viewer $YEAR ($BOTTLE).app"
if [ "$SIGNIN" = adsso ]; then
  echo "First launch: sign in to Autodesk. If Revit hangs on the splash screen, quit it and start again."
else
  echo "First launch: Revit opens Autodesk sign-in in your browser. After signing in, when the browser asks"
  echo "which app should open the link, choose \"Autodesk Sign-In ($BOTTLE)\"."
fi
[ ${#ADDIN_STEPS[@]} -eq 0 ] || echo "Optional add-ins (RevitLookup, pyRevit): ./revit addins $YEAR$SFX"
echo "Everyday commands: ./revit"
[ -z "$problems" ]
