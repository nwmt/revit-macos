# Running Windows programs in a bottle and changing it. Source after common.sh, then call wine_init <bottle>.
# Every Wine process runs with stdin from /dev/null and fd 9 (the lock) closed: wineserver, which Wine starts on
# its own, outlives the script by hours and would hold the lock. say/detail/skip/msi write into $RUN_DIR.

wine_init() { NAME="$1"; B="$(bottle_path "$1")"; }
w()              { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@" </dev/null 9>&-; }
w_nowait()       { "$CX/bin/wine" --bottle "$NAME" "$@" </dev/null 9>&-; }   # services and GUI programs. Backgrounded,
# close fd 9 on the call as well (`w_nowait … 9>&- &`): the subshell that runs the function keeps it otherwise
wineserver_kill() { WINEPREFIX="$B" "$CX/bin/wineserver" -k </dev/null 9>&-; }
win() { echo "Z:$(echo "$1" | tr '/' '\\')"; }   # Windows path for a Mac file

# summary.txt lines (the runner writes one per step; a step with parts adds its own), and the step's result text
say()    { printf '   %-10s exit=%-5s %s\n' "$1" "$2" "$3" | tee -a "$RUN_DIR/summary.txt"; }
detail() { printf '%s' "$*" > "$RUN_DIR/.detail"; }
skip()   { printf '%s' "$*" > "$RUN_DIR/.skip"; }   # "not needed for this version"; the step then returns 0
accept_codes() { # $1 = exit code, rest = codes that mean success. Wine gives the low byte: 194 = 3010 (reboot needed),
  # 102 = 1638 (a newer one is installed), 67 = 1603 (fatal), 103 = 1639 (bad arguments). Returns 0 or 1, never $1
  local rc="$1" okc; shift
  for okc in "$@"; do [ "$rc" = "$okc" ] && return 0; done
  return 1
}

run_exe() { # $1 = name, $2 = Mac path, rest = switches. Copied to C:\<name>.exe: some programs (msidb) silently fail
  # to read Z:\Users\…. Returns the program's code
  local name="$1" src="$2" rc; shift 2
  cp "$src" "$B/drive_c/$name.exe" || return 1
  w "C:\\$name.exe" "$@"; rc=$?
  rm -f "$B/drive_c/$name.exe"
  return $rc
}
install_exe() { # run_exe and a summary line: "<name> exit=<code> <file> <switches> (<s> s)"
  local t0=$SECONDS rc
  run_exe "$@"; rc=$?
  say "$1" "$rc" "$(basename "$2") ${*:3} ($((SECONDS - t0)) s)"
  return $rc
}
msi() { # $1 = name, $2 = Windows path to the MSI, rest = KEY=VALUE properties. Returns msiexec's code.
  # `wine msiexec args…` cannot pass values with spaces (CrossOver escapes quotes as \", Wine's msiexec splits on
  # spaces → 1639): the command line goes into a .cmd file that cmd /c runs
  local name="$1" path="$2" a line rc; shift 2
  line="msiexec /i \"$path\" /qn /norestart ALLUSERS=1"
  for a in "$@"; do case "$a" in *" "*) line+=" ${a%%=*}=\"${a#*=}\"" ;; *) line+=" $a" ;; esac; done
  line+=" /l*v \"C:\\$name.msi.log\""
  printf '@echo off\r\n%s\r\nexit /b %%ERRORLEVEL%%\r\n' "$line" > "$B/drive_c/$name.cmd" || return 1
  cp "$B/drive_c/$name.cmd" "$RUN_DIR/$name.cmd"
  w cmd /c "C:\\$name.cmd"; rc=$?
  rm -f "$B/drive_c/$name.cmd"; mv "$B/drive_c/$name.msi.log" "$RUN_DIR/" 2>/dev/null
  return $rc
}

override() { # DllOverrides native,builtin for the whole bottle (as in the winetricks vcrun recipes)
  local d; for d in "$@"; do w reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native,builtin /f || return 1; done
}
app_override() { w reg add "HKCU\\Software\\Wine\\AppDefaults\\$1\\DllOverrides" /v "$2" /d native,builtin /f; }   # $1 = exe, $2 = dll

put_native_dll() { # $1 = dll name (no .dll), $2 = file, $3 = folder for a second copy ("" = none), rest = exes that
  # get <dll>=native,builtin. Into system32 too: Revit, WPF and the browser load these by their full system32 path,
  # and other programs keep loading the builtin one first. Wine's builtin stub is kept as <dll>.dll.wine-fake. The new
  # file gets a new inode (.new + mv): a process that runs keeps the old one
  local dll="$1" src="$2" dir="$3" s32="$B/drive_c/windows/system32" exe; shift 3
  if LC_ALL=C grep -q -a 'Wine builtin DLL' "$s32/$dll.dll" 2>/dev/null; then cp "$s32/$dll.dll" "$s32/$dll.dll.wine-fake" || return 1; fi
  cp "$src" "$s32/$dll.dll.new" && mv -f "$s32/$dll.dll.new" "$s32/$dll.dll" || return 1
  [ -z "$dir" ] || cp "$src" "$dir/$dll.dll" || return 1
  for exe in "$@"; do app_override "$exe" "$dll" || return 1; done
}

start_service() { # $1 = service. SCM rereads its config only after a wineserver restart; the service never exits,
  # so it starts without --wait-children, in the background. 0 once it reports RUNNING (at most 40 s)
  local st="" i
  wineserver_kill
  w_nowait sc start "$1" </dev/null 9>&- &   # on the outer call too: the subshell that runs a backgrounded function
                                             # would keep fd 9 while it waits for Wine
  for i in $(seq 1 20); do
    st="$(w_nowait sc query "$1" 2>/dev/null | tr -d '\r' | awk '/STATE/{print $4}')"
    [ "$st" = RUNNING ] && return 0
    sleep 2
  done
  echo "$1: ${st:-no state} after 40 s"; return 1
}

bottle_env() { python3 -I "$ROOT/tools/bottle_env.py" "$B/cxbottle.conf" "$@"; }   # KEY=VALUE | -KEY …

sh_path() { # a path inside a command that Wine runs with /bin/sh -c (the PDF printer port). Quoted only when it has
  # to be, so a plain path is written exactly as before
  case "$1" in *[!A-Za-z0-9/._-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;; *) printf '%s' "$1" ;; esac
}
