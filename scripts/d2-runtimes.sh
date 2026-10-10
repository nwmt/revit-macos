#!/usr/bin/env bash
# D2: VC++ 2010–2017 from the Revit installer + corefonts/msxml6 via winetricks.
# Usage: ./scripts/d2-runtimes.sh <bottle>
# DLL overrides follow the winetricks vcrun20xx recipes.
set -uo pipefail

NAME="${1:?specify a bottle}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
DIST="$(ls -d "$ROOT"/installers/extracted/revit2020/*/ | head -1)"
LOG="$ROOT/logs/d2-$NAME-$(date +%Y%m%d-%H%M%S).log"
w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
override() { for d in "$@"; do w reg add 'HKCU\Software\Wine\DllOverrides' /v "$d" /d native,builtin /f >>"$LOG" 2>&1; done; }
run_exe() { # $1 = path inside the installer, rest = switches
  local src="$DIST/$1" tmp="C:\\d2tmp.exe"; shift
  cp "$src" "$B/drive_c/d2tmp.exe"
  w "$tmp" "$@" >>"$LOG" 2>&1; local rc=$?
  rm -f "$B/drive_c/d2tmp.exe"
  printf '   %-45s exit=%s\n' "$(basename "$(dirname "$src")")/$(basename "$src")" "$rc"
}

[ -d "$B" ] || { echo "no bottle $NAME" >&2; exit 1; }
echo ">> log: $LOG"

if [ "${D2_SKIP_VC:-0}" != 1 ]; then
echo ">> 1. VC++ from the installer (0 = ok, 1638/0x666 = newer already installed, 3010 = reboot needed)"
override msvcp100 msvcr100 vcomp100 atl100
run_exe 3rdParty/x86/VCRedist/2010SP1/vcredist_x86.exe /q /norestart
run_exe 3rdParty/x64/VCRedist/2010SP1/vcredist_x64.exe /q /norestart
override atl110 msvcp110 msvcr110 vcomp110
run_exe 3rdParty/x86/VCRedist/2012/vcredist_x86.exe /q /norestart
run_exe 3rdParty/x64/VCRedist/2012/vcredist_x64.exe /q /norestart
override atl120 msvcp120 msvcr120 vcomp120
run_exe 3rdParty/x86/VCRedist/2013/vcredist_x86.exe /q /norestart
run_exe 3rdParty/x64/VCRedist/2013/vcredist_x64.exe /q /norestart
# 2015 and 2017 are the same v14 runtime; install 2017 (newer), skip 2015.
override api-ms-win-crt-private-l1-1-0 api-ms-win-crt-conio-l1-1-0 api-ms-win-crt-heap-l1-1-0 \
  api-ms-win-crt-locale-l1-1-0 api-ms-win-crt-math-l1-1-0 api-ms-win-crt-runtime-l1-1-0 \
  api-ms-win-crt-stdio-l1-1-0 api-ms-win-crt-time-l1-1-0 atl140 concrt140 msvcp140 msvcp140_1 \
  msvcp140_2 msvcp140_atomic_wait ucrtbase vcamp140 vcomp140 vccorlib140 vcruntime140 vcruntime140_1
run_exe 3rdParty/x86/VCRedist/2017/VC_redist.x86.exe /install /quiet /norestart
run_exe 3rdParty/x64/VCRedist/2017/VC_redist.x64.exe /install /quiet /norestart

fi

echo ">> 2. corefonts + msxml6 via winetricks"
WINE="$ROOT/scripts/lib/cxwine" WINESERVER="$CX/bin/wineserver" CX_BOTTLE="$NAME" WINEPREFIX="$B" \
  winetricks -q --unattended corefonts msxml6 >>"$LOG" 2>&1
echo "   winetricks exit=$?"

echo ">> 3. check"
for f in msvcp100 msvcr120 msvcp140 vcruntime140; do
  for d in system32 syswow64; do
    p="$B/drive_c/windows/$d/$f.dll"
    if [ ! -f "$p" ]; then s="MISSING"; elif LC_ALL=C grep -q -a 'Wine builtin DLL' "$p"; then s="Wine stub"; else s="native"; fi
    printf '   %-9s %-18s %s\n' "$d" "$f.dll" "$s"
  done
done
ls "$B/drive_c/windows/Fonts" | grep -i -E '^(arial|times|verdana|cour)' | tr '\n' ' '; echo
