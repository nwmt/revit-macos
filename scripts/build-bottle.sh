#!/usr/bin/env bash
# Builds a Revit 2020 bottle from scratch in one run: D0 bottle → D3 .NET 4.0/4.7 → D2 VC++/fonts → D6 Revit and all workarounds.
# Usage: ./scripts/build-bottle.sh <bottle> [template=win10_64]
# Recreate an existing one: CX_RECREATE=1 ./scripts/build-bottle.sh <bottle>
# Requires (installers/, see installers/README.md): Revit SFX (extracted to installers/extracted/revit2020),
#   redist/dotNetFx40_Full_x86_x64.exe, redist/win7sp1/x64/{riched20,usp10,msls31}.dll; toolchain (scripts/get-toolchain.sh);
#   brew: sevenzip winetricks ghostscript. After the build: first launch with d7-launch.sh and Autodesk sign-in (manual).
set -uo pipefail
NAME="${1:?specify a bottle}"; TEMPLATE="${2:-win10_64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$(date +%Y%m%d-%H%M%S)"; LOG="$ROOT/logs/build-$NAME-$RUN.log"; mkdir -p "$ROOT/logs"
step() { # $1 = name, rest = command
  local t0=$SECONDS name="$1"; shift
  echo "=== $(date +%T) $name: $*" | tee -a "$LOG"
  "$@" >>"$LOG" 2>&1; local rc=$?
  echo "--- $name rc=$rc in $((SECONDS - t0)) s" | tee -a "$LOG"
  return $rc
}
# The Mac's own hostname must resolve: otherwise every getaddrinfo(hostname) in Revit hits a 5 s timeout.
H="$(hostname)"
grep -qE "[[:space:]]$H([[:space:]]|\$)" /etc/hosts || echo "!! $H is not in /etc/hosts — Revit will be slower: sudo sh -c 'printf \"127.0.0.1\\t$H\\n::1\\t$H\\n\" >> /etc/hosts'" | tee -a "$LOG"
step D0-bottle   "$ROOT/scripts/cx-bottle.sh" "$NAME" "$TEMPLATE" || exit 1
step D3-dotnet   "$ROOT/scripts/d3-dotnet47.sh" "$NAME" || exit 1
step D2-runtimes "$ROOT/scripts/d2-runtimes.sh" "$NAME" || exit 1
step D6-revit    "$ROOT/scripts/d6-install-revit.sh" "$NAME" || exit 1
echo "=== D6 summary:" | tee -a "$LOG"
cat "$(ls -td "$ROOT"/logs/d6-"$NAME"-*/ | head -1)summary.txt" | tee -a "$LOG"
echo "done in $((SECONDS / 60)) min; log $LOG" | tee -a "$LOG"
