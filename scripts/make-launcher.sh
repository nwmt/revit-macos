#!/usr/bin/env bash
# Creates macOS apps in ~/Applications for the Revit shortcuts in the bottle, with their own icons:
#   Revit <year> (<bottle>).app, and Revit Viewer <year> (<bottle>).app where the version has a Viewer.
# Usage: ./scripts/make-launcher.sh <bottle> [year]
#   year: argument, else $REVIT_YEAR, else the 4 digits in the bottle name (rvt2026-a → 2026), else 2020.
# Why: CrossOver 26 cxmenu doesn't create an app for "Revit <year>.lnk". The command line (/viewer, /language …)
# and the icon come from the installer's Start Menu shortcuts (tools/win_shortcut.py), so nothing is hardcoded per year.
set -euo pipefail
NAME="${1:?specify a bottle}"
YEAR="${2:-${REVIT_YEAR:-}}"
if [ -z "$YEAR" ]; then
  if [[ "$NAME" =~ ([0-9]{4}) ]]; then YEAR="${BASH_REMATCH[1]}"; else YEAR=2020; fi
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
CXW="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
MENU="$B/drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Autodesk/Revit $YEAR"
unix_path() { local p="${1#[Cc]:}"; echo "$B/drive_c${p//\\//}"; }   # C:\a\b → <bottle>/drive_c/a/b

make_app() { # $1 = app title, $2 = Windows exe path, $3 = arguments, $4 = icon (Windows path, may be empty)
  local app="$HOME/Applications/$1 ($NAME).app" exe="${2//\\/\\\\}"
  rm -rf "$app"
  osacompile -o "$app" -e "do shell script \"cd ~ && '$CXW' --bottle '$NAME' '$exe' $3 >/dev/null 2>&1 &\""
  local ico; ico="$(unix_path "$4")"
  if [ -n "$4" ] && [ -f "$ico" ]; then
    if python3 -I "$ROOT/tools/win_shortcut.py" icns "$ico" "$app/Contents/Resources/applet.icns"; then
      # osacompile also ships the script icon in Assets.car, which macOS prefers over applet.icns
      rm -f "$app/Contents/Resources/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$app/Contents/Info.plist" 2>/dev/null || true
    else echo "   (no icon: conversion failed)"; fi
  fi
  # osacompile writes no bundle id; Launchpad/Apps skip bundles without one (Spotlight still finds them)
  local id; id="local.revit-macos.$(printf '%s-%s' "$1" "$NAME" | tr -cs 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]' | sed 's/-$//')"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $id" -c "Add :CFBundleDisplayName string $1 ($NAME)" \
    -c "Add :LSApplicationCategoryType string public.app-category.graphics-design" "$app/Contents/Info.plist"
  # changing the bundle invalidates the osacompile signature; re-sign ad hoc so Gatekeeper lets it start
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  touch "$app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
  echo "done: $app"
}

made=0
for title in "Revit $YEAR" "Revit Viewer $YEAR"; do
  lnk="$MENU/$title.lnk"
  [ -f "$lnk" ] || continue
  IFS=$'\t' read -r target args icon < <(python3 -I "$ROOT/tools/win_shortcut.py" info "$lnk")
  make_app "$title" "$target" "$args" "$icon"; made=$((made + 1))
done
# no Start Menu shortcuts (unusual install): plain Revit without an icon
[ $made -gt 0 ] || make_app "Revit $YEAR" "C:\\Program Files\\Autodesk\\Revit $YEAR\\Revit.exe" "" ""
