#!/usr/bin/env bash
# Environment snapshot. Idempotent, changes nothing.
# Usage: ./scripts/check-env.sh [> logs/env-$(date +%F).txt]
set -uo pipefail

hr() { printf '\n== %s ==\n' "$1"; }

hr "macOS"
sw_vers
printf 'arch: %s / %s\n' "$(uname -m)" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
sysctl -n hw.memsize | awk '{printf "ram: %.0f GB\n", $1/1024/1024/1024}'
df -h / /System/Volumes/Data | awk 'NR==1 || /disk/ {print}'

hr "Rosetta 2"
if pgrep -q oahd; then echo "ok: oahd daemon running"; else echo "MISSING: softwareupdate --install-rosetta --agree-to-license"; fi

hr "CLI"
for t in git brew xcode-select wine wine64 wineserver winetricks cabextract 7z msiextract; do
  printf '%-12s %s\n' "$t" "$(command -v "$t" || echo '— not installed')"
done

hr "Applications"
for a in /Applications/CrossOver.app /Applications/Kegworks.app /Applications/Whisky.app \
         /Applications/Wine*.app "/Applications/Parallels Desktop.app" "/Applications/VMware Fusion.app"; do
  [ -e "$a" ] && printf 'found: %s\n' "$a"
done
if [ -f /Applications/CrossOver.app/Contents/Info.plist ]; then
  printf 'CrossOver version: %s\n' \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
       /Applications/CrossOver.app/Contents/Info.plist 2>/dev/null)"
fi

hr "Wine prefixes"
ls -d "$HOME/Library/Application Support/CrossOver/Bottles"/* 2>/dev/null || echo "no CrossOver bottles"
ls -d "$HOME/.wine" ./prefixes/* 2>/dev/null || echo "no wine prefixes"

hr "Installers (installers/)"
du -sh installers/* 2>/dev/null || echo "empty — see installers/README.md"
