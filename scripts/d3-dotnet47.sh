#!/usr/bin/env bash
# D3: real .NET Framework 4.0 → 4.7 in a CrossOver bottle (based on winetricks dotnet4x).
# Usage: ./scripts/d3-dotnet47.sh <bottle>
# Requires: installers/redist/dotNetFx40_Full_x86_x64.exe (provides mscoree.dll, which 4.5+ lacks)
#           and the extracted Revit installer (source of dotNetFx47_Full_x86_x64.exe).
set -uo pipefail

NAME="${1:?specify a bottle}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
NET40="$ROOT/installers/redist/dotNetFx40_Full_x86_x64.exe"
NET47="$(ls "$ROOT"/installers/extracted/revit2020/*/3rdParty/NET/47/wcu/dotNetFramework/dotNetFx47_Full_x86_x64.exe 2>/dev/null | head -1)"
LOG="$ROOT/logs/d3-$NAME-$(date +%Y%m%d-%H%M%S).log"
w() { "$CX/bin/wine" --bottle "$NAME" --wait-children "$@"; }
mscoree_state() {
  for d in system32 syswow64; do
    f="$B/drive_c/windows/$d/mscoree.dll"
    if [ ! -f "$f" ]; then echo "   $d/mscoree.dll: MISSING"
    elif LC_ALL=C grep -q -a 'Wine builtin DLL' "$f"; then echo "   $d/mscoree.dll: Wine stub"
    else echo "   $d/mscoree.dll: native Microsoft"; fi
  done
}
install_net() { # $1 = source, $2 = name in C:\, rest = switches
  local src="$1" dst="$2"; shift 2
  cp "$src" "$B/drive_c/$dst"
  WINEDLLOVERRIDES="fusion=b" w "C:\\$dst" "$@" >>"$LOG" 2>&1
  local rc=$?
  rm -f "$B/drive_c/$dst"
  echo "   exit=$rc (0 or 3010 = success)" | tee -a "$LOG"
  return 0
}

[ -d "$B" ] || { echo "no bottle $NAME" >&2; exit 1; }
[ -f "$NET40" ] || { echo "no $NET40" >&2; exit 1; }
[ -f "$NET47" ] || { echo "no dotNetFx47 — extract the installer first" >&2; exit 1; }
echo ">> log: $LOG"

echo ">> 1. removing builtin mscoree traces: fake NDP keys and stub DLLs"
for k in 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' \
         'HKLM\Software\Wow6432Node\Microsoft\NET Framework Setup\NDP\v4'; do
  w reg delete "$k" /f >>"$LOG" 2>&1 || true
done
rm -f "$B/drive_c/windows/system32/mscoree.dll" "$B/drive_c/windows/syswow64/mscoree.dll"

echo ">> 2. .NET 4.0 as winxp64 (base: installs the real mscoree.dll)"
w winecfg -v winxp64 >>"$LOG" 2>&1
install_net "$NET40" dotNetFx40.exe /q '/c:install.exe /q'
mscoree_state
w reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f >>"$LOG" 2>&1
for k in 'HKLM\Software\Microsoft\.NETFramework' 'HKLM\Software\Wow6432Node\.NETFramework'; do
  w reg add "$k" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >>"$LOG" 2>&1
done

echo ">> 3. .NET 4.7 from the Revit installer as win7"
# On Win10 1703+ the 4.7 installer is blocked by OS version ("already installed").
w winecfg -v win7 >>"$LOG" 2>&1
install_net "$NET47" dotNetFx47.exe /q /norestart /log 'C:\net47-setup'
cp "$B"/drive_c/net47-setup* "$ROOT/logs/" 2>/dev/null || true

echo ">> 4. back to win10"
w winecfg -v win10 >>"$LOG" 2>&1

echo ">> 5. registry and mscoree"
w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>>"$LOG" | tr -d '\r' | grep Release
w reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Version 2>>"$LOG" | tr -d '\r' | grep Version
mscoree_state

echo ">> 6. smoke test: bundled managed exe, then csc + run"
w 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\RegAsm.exe' '/?' 2>>"$LOG" | tr -d '\r' | grep -v '^$' | head -2
echo "   RegAsm exit=${PIPESTATUS[0]}"
cat > "$B/drive_c/hello.cs" <<'CS'
using System;
class P { static void Main() {
  Console.WriteLine("CLR " + Environment.Version + " x64=" + Environment.Is64BitProcess);
  Console.WriteLine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory());
}}
CS
w 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /out:'C:\hello.exe' 'C:\hello.cs' 2>>"$LOG" | tr -d '\r'
w 'C:\hello.exe' 2>>"$LOG" | tr -d '\r'
