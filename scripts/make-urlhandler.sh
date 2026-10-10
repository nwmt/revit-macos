#!/usr/bin/env bash
# Creates ~/Applications/Autodesk Sign-In (<bottle>).app — a macOS handler for adskidmgr:// and adsk.idmgr:// links.
# Usage: ./scripts/make-urlhandler.sh <bottle>
# Why (Revit 2026+): Autodesk sign-in goes through AdskIdentityManager, which opens the sign-in page in the macOS browser;
# after sign-in the page returns to the product via an adskidmgr://… link. The scheme is registered only in the bottle's
# registry (HKCU\Software\Classes\adskidmgr → AdskIdentityManager.exe "%1"), macOS doesn't know it → "Opening product" and nothing.
# The app receives the link and passes it to AdskIdentityManager.exe in the bottle. The link carries a one-time code —
# it is never logged.
set -euo pipefail
NAME="${1:?specify a bottle}"
B="$HOME/Library/Application Support/CrossOver/Bottles/$NAME"
CXW="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
ver="$(ls "$B/drive_c/Program Files/Autodesk/AdskIdentityManager" 2>/dev/null | grep -E '^[0-9]+\.[0-9.]+$' | sort -V | tail -1 || true)"
[ -n "$ver" ] || { echo "no AdskIdentityManager in $NAME" >&2; exit 1; }
EXE="C:\\\\Program Files\\\\Autodesk\\\\AdskIdentityManager\\\\$ver\\\\AdskIdentityManager.exe"
APP="$HOME/Applications/Autodesk Sign-In ($NAME).app"
rm -rf "$APP"
# The redirect covers the whole ( ) group, or the backgrounded shell keeps do shell script waiting (see make-launcher.sh).
osacompile -o "$APP" -e "on open location u
  do shell script \"(cd ~ && '$CXW' --bottle '$NAME' '$EXE' \" & quoted form of u & \") >/dev/null 2>&1 &\"
end open location"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.revit-macos.adsk-signin.$NAME" "$P" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.revit-macos.adsk-signin.$NAME" "$P"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" \
  -c "Add :CFBundleURLTypes:0 dict" -c "Add :CFBundleURLTypes:0:CFBundleURLName string Autodesk Identity Manager" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string adskidmgr" \
  -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string adsk.idmgr" "$P"
# editing Info.plist invalidates the osacompile signature — re-sign ad-hoc, otherwise Gatekeeper blocks the launch
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "done: $APP (AdskIdentityManager $ver, bottle $NAME)"
