# Shared wrappers for install steps in a CrossOver bottle. Source after setting NAME, ROOT, LOGDIR:
#   . "$ROOT/scripts/lib/bottle.sh"
# Provides: CX, B (bottle path), w (wine with wait), say (summary line), run_exe, msi_win, override.
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
[ -d "$B" ] || { echo "no bottle $NAME" >&2; exit 1; }

w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
say() { printf '   %-10s exit=%-5s %s\n' "$1" "$2" "$3" | tee -a "$LOGDIR/summary.txt"; } # step, code, what

# Windows path for a Mac file. Some programs (msidb) silently fail to read Z:\Users\… —
# so installers are copied to the bottle's C:\ (run_exe).
win() { echo "Z:$(echo "$1" | tr '/' '\\')"; }

run_exe() { # $1 = step, $2 = Mac path, rest = switches. Copied to C:\<step>.exe so it doesn't depend on Z:
  local step="$1" src="$2" t0=$SECONDS; shift 2
  cp "$src" "$B/drive_c/$step.exe"
  w "C:\\$step.exe" "$@" >>"$LOGDIR/wine.log" 2>&1; local rc=$?
  rm -f "$B/drive_c/$step.exe"
  say "$step" "$rc" "$(basename "$src") $* ($((SECONDS - t0)) s)"
  return $rc
}

override() { # DllOverrides native,builtin (as in winetricks vcrun recipes)
  local d; for d in "$@"; do w reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native,builtin /f >>"$LOGDIR/wine.log" 2>&1; done
}

msi_win() { # $1 = step, $2 = Windows path to MSI, rest = KEY=VALUE properties.
  # `wine msiexec args...` can't pass values with spaces (CrossOver escapes quotes as \",
  # Wine's msiexec splits on spaces → 1639) — so write the command line to a .cmd and run it via cmd /c.
  local step="$1" msi="$2" t0=$SECONDS a; shift 2
  local line="msiexec /i \"$msi\" /qn /norestart ALLUSERS=1"
  for a in "$@"; do case "$a" in *" "*) line+=" ${a%%=*}=\"${a#*=}\"" ;; *) line+=" $a" ;; esac; done
  line+=" /l*v \"C:\\$step.msi.log\""
  printf '@echo off\r\n%s\r\nexit /b %%ERRORLEVEL%%\r\n' "$line" > "$B/drive_c/$step.cmd"
  cp "$B/drive_c/$step.cmd" "$LOGDIR/$step.cmd"
  w cmd /c "C:\\$step.cmd" >>"$LOGDIR/wine.log" 2>&1; local rc=$?
  rm -f "$B/drive_c/$step.cmd"; mv "$B/drive_c/$step.msi.log" "$LOGDIR/" 2>/dev/null
  # Wine returns the msiexec code as its low byte: 67 = 1603, 103 = 1639, 194 = 3010 (ok + reboot)
  say "$step" "$rc" "$msi ($((SECONDS - t0)) s)"
  return $rc
}
