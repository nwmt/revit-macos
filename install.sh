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
need() { echo "  ✗ $1"; echo "      fix: $2"; missing=1; emit message level "$(json_str error)" text "$(json_str "$1 — $2")"; }
warn() { echo "  ! $1"; echo "      $2"; emit message level "$(json_str warn)" text "$(json_str "$1 — $2")"; }
echo "Checking requirements for Revit $YEAR (bottle $BOTTLE)…"
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]; then
  need "Apple Silicon Mac required" "this setup is tested on M-series Macs only"
elif [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
  need "this Terminal runs under Rosetta" "quit Terminal, turn off \"Open using Rosetta\" in its Get Info window, and run again"
fi
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || need "Rosetta 2 is not installed" "softwareupdate --install-rosetta --agree-to-license"
[ -x "$CX/bin/cxbottle" ] || need "CrossOver not found in /Applications" "install it from https://www.codeweavers.com/crossover (trial available)"
for t in 7zz:sevenzip winetricks:winetricks cabextract:cabextract python3:python3; do
  command -v "${t%%:*}" >/dev/null || need "${t%%:*} not found" "brew install ${t#*:}"
done
SRC="$(revit_input "$YEAR")"; DST="$(revit_extracted "$YEAR")"; DLD="$(revit_downloads "$YEAR")"
SL="$(mktemp "${TMPDIR:-/tmp}/revit-source.XXXXXX")"; trap 'rm -f "$SL"' EXIT
kind=""; complete=0; GET=""; UNPACK_AGAIN=""; rrc=""; rerr=""
if command -v 7zz >/dev/null && command -v python3 >/dev/null; then   # else the tools check above already said so
  resolved="$(python3 -I "$ROOT/tools/installer_source.py" resolve "$YEAR" "$SRC" "$DLD" "$ROOT/installers/CHECKSUMS.txt" "$SL" 2>"$SL.err")"; rrc=$?
  case $rrc in
    0) kind="$(sed -n 's/^kind=\([^ ]*\).*/\1/p' <<<"$resolved")"; complete="$(sed -n 's/.*complete=//p' <<<"$resolved")" ;;
    3) ;;   # nothing there
    *) rerr="$(head -1 "$SL.err")"; [ -n "$rerr" ] || rerr="error $rrc" ;;   # decided below: it matters only if used
  esac
  rm -f "$SL.err"
fi
problem="$(/usr/bin/perl -MJSON::PP -0 -ne 'print eval { decode_json($_)->{problem} } // ""' "$SL" 2>/dev/null)"
# an unpack that was cut short while swapping folders: settle that first, so the decisions below see the real state.
# It changes files: only under the lock (./revit holds it for install.sh); a dry run only reports it
if ls -d "$DST".old.* >/dev/null 2>&1; then
  if lock_fd_ours && lock_flock9; then extracted_recover "$DST"
  else need "an unpack of Revit $YEAR was cut short" "run ./revit install $YEAR$SFX (it puts the unpacked files back in order first)"; fi
fi
if [ -n "$rerr" ]; then   # an installer that cannot be read stops only an install that would read it
  if [ ! -d "$DST" ] || [ "${REVIT_REEXTRACT:-0}" = 1 ]; then
    need "cannot read the Revit $YEAR installer: $rerr" "download it again from your Autodesk Account"
  elif [ "${REVIT_REUSE_EXTRACTED:-0}" != 1 ] && [ -f "$DST/.source" ]; then   # cannot tell whether it is the unpacked one
    need "cannot read the Revit $YEAR installer: $rerr" \
         "download it again from your Autodesk Account, or ./revit install $YEAR$SFX --reuse-extracted to use installers/extracted/revit$YEAR"
  fi   # an unpacked folder made before .source: used as before
elif [ -d "$DST" ]; then
  if [ "${REVIT_REEXTRACT:-0}" = 1 ]; then
    if o="$(other_bottle_of_year)"; then
      result_set result in_use
      need "installers/extracted/revit$YEAR is in use" "bottle $o still uses it; remove that bottle first, or install from the unpacked files with --reuse-extracted"
    elif [ "$complete" = 1 ] || [ "$kind" = create-installer ]; then
      UNPACK_AGAIN=1; [ "$kind" = create-installer ] && GET=1
    else need "the Revit $YEAR installer is not complete" "--reextract needs every installer file in installers/revit$YEAR/"; fi
  elif [ "${REVIT_REUSE_EXTRACTED:-0}" != 1 ] && [ -f "$DST/.source" ] && [ -n "$kind" ]; then
    cmp_="$(python3 -I "$ROOT/tools/installer_source.py" compare "$SL" "$DST/.source" "$DATA/installers/.hashes" 2>&1)" \
      || need "cannot check installers/extracted/revit$YEAR against the installer: $cmp_" "see docs/troubleshooting.md"
    case "$cmp_" in
      mismatch*) result_set result source_mismatch
        need "installers/extracted/revit$YEAR was unpacked from another installer (${cmp_#mismatch })" \
             "./revit install $YEAR$SFX --reuse-extracted to use it anyway, or --reextract to unpack this installer" ;;
    esac
  fi
else
  [ "$kind" = create-installer ] && GET=1   # as today: the downloader runs, and says "already here" for what is
  if [ -z "$kind" ] && [ "${rrc:-1}" = 3 ]; then   # without 7zz/python3 the tools check has said so already
    need "no Revit $YEAR installer in installers/revit$YEAR/" "download it from your Autodesk Account, see installers/README.md"
    need "no .7z payload in installers/revit$YEAR/ (the small .exe alone is only the downloader)" \
         "download both files of the Autodesk download, see versions/$YEAR.md"   # today's preflight says both
  elif [ "$kind" = parts ] && [ "$complete" != 1 ]; then
    gone="$(/usr/bin/perl -MJSON::PP -0 -ne 'for (@{decode_json($_)->{files}}) { print " $1" if !-f $_->{path} && $_->{path} =~ /_(\d{3})_\d{3}\.sfx\.exe$/i }' "$SL")"
    tot3="$(/usr/bin/perl -MJSON::PP -0 -ne 'my ($f) = @{decode_json($_)->{files}}; print $1 if $f->{path} =~ /_\d{3}_(\d{3})\.sfx\.exe$/i' "$SL")"
    need "installer parts missing in installers/revit$YEAR/:$gone (of $tot3)" "download all parts from your Autodesk Account"
  elif [ "$problem" = payload ] || [ "$kind" = updates-only ]; then   # today: an update/*.exe alone gets this too
    need "no .7z payload in installers/revit$YEAR/ (the small .exe alone is only the downloader)" \
         "download both files of the Autodesk download, see versions/$YEAR.md"
  fi
fi
export REVIT_SOURCE_LIST="$SL" REVIT_UNPACK_AGAIN="$UNPACK_AGAIN" REVIT_FOR_BOTTLE="$BOTTLE"
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
[ $missing -eq 0 ] || { echo; echo "Fix the items marked ✗ and run ./revit install $YEAR$SFX again."; result_default failed; exit 1; }
[ "${INSTALL_DRYRUN:-0}" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }

# ---- run ----
lock_take "install.sh $YEAR $BOTTLE"
bottle_guard allow_missing "$YEAR" "$BOTTLE"
[ ! -d "$B" ] || [ "${CX_RECREATE:-0}" = 1 ] || die "Bottle $BOTTLE already exists. To rebuild it: ./revit rebuild $YEAR$SFX"
RUN_DIR="$(run_dir_new "$BOTTLE" install)" || die "Cannot create a log folder in $(tilde "$DATA/logs")."
export RUN_DIR
cp "$SL" "$RUN_DIR/source.list"; export REVIT_SOURCE_LIST="$RUN_DIR/source.list"
result_set log_dir "$RUN_DIR"; export INSTALL_PARENT=1   # the runner leaves the final result to this script
echo; echo "Logs: $(tilde "$RUN_DIR")"
t0=$SECONDS; i=1
for a in "${PLAN[@]}"; do
  stop_check
  action_argv "$a"; echo; echo "==> [$i/${#PLAN[@]}] ${A[*]}"; t=$SECONDS
  # the action's output also goes to action-<name>.log (new-bottle.sh and run-steps.sh write their own logs as well)
  emit action id "$(json_str "$a")" state "$(json_str running)"
  run_child --log "$RUN_DIR/action-$a.log" "$ROOT/${A[0]}" "${A[@]:1}"; rc=$?
  emit action id "$(json_str "$a")" state "$(json_str "$([ $rc = 0 ] && echo done || echo failed)")" exit "$rc"
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
    result_set failed_action "$a"; result_set result failed
    exit 1
  fi
  i=$((i + 1))
done

# installers report errors in their own way; check the result instead of trusting exit codes
if [ ! -f "$(revit_dir_unix "$B" "$YEAR")/Revit.exe" ]; then
  echo; echo "Install finished, but Revit.exe is not in the bottle. Logs: ./revit logs $YEAR$SFX. To start over: ./revit rebuild $YEAR$SFX" >&2
  result_set result failed
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
echo "PDF printer (needs Ghostscript: brew install ghostscript): ./revit addins $YEAR$SFX --only pdfprinter"
echo "Everyday commands: ./revit"
result_set failed_steps "$(tr '\n' ' ' 2>/dev/null < "$RUN_DIR/failed.txt" | sed 's/ $//')"
if [ -z "$problems" ]; then result_set result ok; exit 0; fi
result_set result partial; exit 1
