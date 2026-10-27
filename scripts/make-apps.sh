#!/usr/bin/env bash
# Creates the macOS apps for a Revit bottle in ~/Applications:
#   Revit <year> (<bottle>).app and, when the installer made its shortcut, Revit Viewer <year> (<bottle>).app (Revit
#   started with /viewer), with their icons;
#   Autodesk Sign-In (<bottle>).app when Revit signs in through the browser (profile SIGNIN=idmgr): the handler for
#   adskidmgr:// and adsk.idmgr:// links, which passes them to AdskIdentityManager.exe in the bottle.
# Usage: ./scripts/make-apps.sh <year> <bottle> [--revit-only]   (--revit-only: the Revit app alone, for ./revit set)
# Why: CrossOver 26 cxmenu makes no app for "Revit <year>.lnk", and macOS does not know the sign-in link scheme (only
# the bottle's registry has it: "Opening product" and nothing). The command line (/viewer, /language …) and the icon
# come from the installer's Start Menu shortcuts (tools/win_shortcut.py), so nothing is hardcoded per year. The sign-in
# link carries a one-time code: it is never logged. The Revit app first starts the bottle's wineserver under
# scripts/watch-server.pl (a copy in <bottle>/revit-macos), which writes down how it ends. Where the profile has the
# step theme (2027), it then sets the bottle's Windows theme from the Mac's look (themeset.exe in the bottle, when its
# mode file says mac), so Revit starts in it. Each app is built beside the old one and replaces it only when complete.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"
REVIT_ONLY=0; [ $# -eq 3 ] && [ "$3" = --revit-only ] && REVIT_ONLY=1
[ $# -eq 2 ] || [ $REVIT_ONLY = 1 ] || usage_die "Usage: scripts/make-apps.sh <year> <bottle> [--revit-only]"
load_profile "$1" || usage_die "Revit $1 is not supported yet. Supported: ${REVIT_SUPPORTED[*]}."
NAME="$2"; revit_bottle_name_ok "$NAME" || usage_die "Bottle name may contain only letters, digits, - and _: \"$NAME\""
lock_take "make-apps.sh $YEAR $NAME"
bottle_guard running_ok "$YEAR" "$NAME"
B="$(bottle_path "$NAME")"; CXW="$CX/bin/wine"
MENU="$B/drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Autodesk/Revit $YEAR"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DEFAULTS="${REVIT_DEFAULTS:-/usr/bin/defaults}"   # tests: a fake one
sq()   { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }   # one shell word, single-quoted
as_q() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }   # a shell line inside an AppleScript "…" string
theme_prefix() { # the Revit app's first part where the profile has the step theme: the Windows theme from the Mac's
  # look, only when the bottle's mode is mac and themeset.exe is there; whatever happens, Revit starts after it
  local d="$B/drive_c/Program Files/revit-macos"
  in_list theme ${STEPS[@]+"${STEPS[@]}"} || return 0
  printf '%s' ": revit-macos/theme; d=$(sq "$d"); if [ \"\$(cat \"\$d/theme\" 2>/dev/null)\" = mac ] && [ -f \"\$d/themeset.exe\" ]; then t=light; $(sq "$DEFAULTS") read -g AppleInterfaceStyle 2>/dev/null | /usr/bin/grep -qi dark && t=dark; $(sq "$CXW") --bottle $(sq "$NAME") 'C:\\Program Files\\revit-macos\\themeset.exe' \"\$t\"; fi; "
}
watch_copy() { # the Revit app's copy of scripts/watch-server.pl in the bottle: the app runs it wherever the repo is
  local d="$B/revit-macos"
  mkdir -p "$d" && cp "$ROOT/scripts/watch-server.pl" "$d/watch-server.pl.new" && mv "$d/watch-server.pl.new" "$d/watch-server.pl"
}
watch_prefix() { # the Revit app's first part, every year: the bottle's wineserver under watch-server (its log and how it
  # ends, for ./revit doctor and report), when the copy is there; whatever happens, Revit starts after it
  local w="$B/revit-macos/watch-server.pl"
  printf '%s' ": revit-macos/watch-server; [ -f $(sq "$w") ] && /usr/bin/perl $(sq "$w") $(sq "$CX") $(sq "$B") 7>&- 8>&- 9>&-; "
}
unix_path() { local p="${1#[Cc]:}"; echo "$B/drive_c${p//\\//}"; }   # C:\a\b → <bottle>/drive_c/a/b

make_app() { # $1 = app title, $2 = Windows exe path, $3 = arguments, $4 = icon (Windows path, may be empty). Built in a
  # hidden .new.app (osacompile makes an app only for a path ending in .app), which replaces the old app when complete
  local app="$HOME/Applications/$1 ($NAME).app" tmp="$HOME/Applications/.$1 ($NAME).new.app" line pre=""
  if [ "$1" = "Revit $YEAR" ]; then watch_copy || return 1; pre="$(watch_prefix)$(theme_prefix)"; fi
  rm -rf "$tmp"
  # The redirect covers the whole ( ) group: with `cd ~ && wine … >/dev/null &` the backgrounded shell keeps
  # do shell script's output pipe open, so the applet waits (and sits in the Dock) until Revit quits.
  line="(cd ~ && $pre$(sq "$CXW") --bottle $(sq "$NAME") $(sq "$2") $3) >/dev/null 2>&1 &"
  if ! make_app_in "$tmp" "$1" "$line" "$4"; then rm -rf "$tmp"; return 1; fi
  rm -rf "$app" && mv "$tmp" "$app" || { rm -rf "$tmp"; return 1; }
  touch "$app"
  "$LSREGISTER" -f "$app" 2>/dev/null || true
  echo "done: $(tilde "$app")"
}
make_app_in() { # $1 = bundle to build, $2 = app title, $3 = the shell line it runs, $4 = icon (Windows path, may be empty)
  local ico id
  osacompile -o "$1" -e "do shell script \"$(as_q "$3")\"" || return 1
  ico="$(unix_path "$4")"
  if [ -n "$4" ] && [ -f "$ico" ]; then
    if python3 -I "$ROOT/tools/win_shortcut.py" icns "$ico" "$1/Contents/Resources/applet.icns"; then
      # osacompile also ships the script icon in Assets.car, which macOS prefers over applet.icns
      rm -f "$1/Contents/Resources/Assets.car"
      /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$1/Contents/Info.plist" 2>/dev/null || true
    else echo "   (no icon: conversion failed)"; fi
  fi
  # osacompile writes no bundle id; Launchpad/Apps skip bundles without one (Spotlight still finds them)
  id="local.revit-macos.$(printf '%s-%s' "$2" "$NAME" | tr -cs 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]' | sed 's/-$//')"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $id" -c "Add :CFBundleDisplayName string $2 ($NAME)" \
    -c "Add :LSApplicationCategoryType string public.app-category.graphics-design" "$1/Contents/Info.plist" || return 1
  # changing the bundle invalidates the osacompile signature; re-sign ad hoc so Gatekeeper lets it start (an app left
  # unsigned would not: the old one stays then)
  codesign --force --sign - "$1" >/dev/null 2>&1
}

make_signin() { # Autodesk Sign-In (<bottle>).app: receives the link and passes it to AdskIdentityManager.exe
  local ver exe app="$HOME/Applications/Autodesk Sign-In ($NAME).app" p
  ver="$(ls "$B/drive_c/Program Files/Autodesk/AdskIdentityManager" 2>/dev/null | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1)"
  [ -n "$ver" ] || { echo "no AdskIdentityManager in $NAME" >&2; return 1; }
  exe="C:\\\\Program Files\\\\Autodesk\\\\AdskIdentityManager\\\\$ver\\\\AdskIdentityManager.exe"
  rm -rf "$app"
  osacompile -o "$app" -e "on open location u
  do shell script \"(cd ~ && '$CXW' --bottle '$NAME' '$exe' \" & quoted form of u & \") >/dev/null 2>&1 &\"
end open location" || return 1
  p="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.revit-macos.adsk-signin.$NAME" "$p" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.revit-macos.adsk-signin.$NAME" "$p" || return 1
  /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" \
    -c "Add :CFBundleURLTypes:0 dict" -c "Add :CFBundleURLTypes:0:CFBundleURLName string Autodesk Identity Manager" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string adskidmgr" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string adsk.idmgr" "$p" || return 1
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$app" || return 1
  echo "done: $(tilde "$app") (AdskIdentityManager $ver)"
}

made=0; viewer=0
titles=("Revit $YEAR"); [ $REVIT_ONLY = 1 ] || titles+=("Revit Viewer $YEAR")
for title in "${titles[@]}"; do
  lnk="$MENU/$title.lnk"
  [ -f "$lnk" ] || continue
  info="$(python3 -I "$ROOT/tools/win_shortcut.py" info "$lnk")" || die "Cannot read the shortcut $(tilde "$lnk")."
  # \037, not tab: read merges empty tab-separated fields, which would move the icon into the arguments
  IFS=$'\037' read -r target args icon <<<"$(printf '%s' "$info" | tr '\t' '\037')"
  [ -n "$target" ] || die "The shortcut $(tilde "$lnk") names no program."
  make_app "$title" "$target" "$args" "$icon" || exit 1; made=$((made + 1))
  [ "$title" = "Revit $YEAR" ] || viewer=1
done
# no Start Menu shortcuts (unusual install): plain Revit without an icon
if [ $made -eq 0 ]; then make_app "Revit $YEAR" "C:\\Program Files\\Autodesk\\Revit $YEAR\\Revit.exe" "" "" || exit 1; fi
# Revit Viewer only where the installer made its shortcut: 2027 has no Viewer mode (its /viewer starts full Revit).
# An app left from an earlier run goes.
[ $REVIT_ONLY = 1 ] && exit 0
[ $viewer = 1 ] || rm -rf "$HOME/Applications/Revit Viewer $YEAR ($NAME).app"
[ "$SIGNIN" != idmgr ] || make_signin || exit 1
