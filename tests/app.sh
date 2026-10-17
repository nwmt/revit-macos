#!/usr/bin/env bash
# Tests for the app bundle: the engine inside <App>.app (the .app-bundle marker, placement, a read-only bundle), the
# scripts in app/ that fetch the tools, assemble, sign and make the DMG. In a sandbox: a copy of the repo, a fake HOME,
# fixture tools. Runs under /bin/bash 3.2. Nothing real is touched. Usage: tests/app.sh
set -uo pipefail
# every control variable of the engine: none of the caller's may reach the sandbox; tests set what they need after this
CLEAN_ENV=(-u REVIT_DATA -u REVIT_LOCK_DIR -u SHIMS_DIR -u REVIT_BUNDLED -u REVIT_EVENTS_FD -u REVIT_RUN_ID -u REVIT_RUN_CTX
  -u REVIT_ACCEPT_EULA -u REVIT_SOURCE_LIST -u REVIT_REUSE_EXTRACTED -u REVIT_REEXTRACT -u REVIT_UNPACK_AGAIN
  -u REVIT_FOR_BOTTLE -u INSTALL_PARENT -u W_CACHE -u SHIMS_FROM_SOURCE -u RUN_DIR -u RUN_KIND -u CX_RECREATE
  -u INSTALL_DRYRUN -u REVIT_LANG -u ODIS_PKGS -u REVIT_THEME -u REVIT_YEAR -u APP_NAME -u APP_RES)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }
TOP="$(cd "$TMP" && pwd -P)" || exit 1
T="$TOP/sand box"                      # a space in every path
R="$T/repo"; H="$T/home"; CALLS="$T/calls"
A="$H/Applications/Test App.app"       # where a user keeps the app
HOST_7ZZ="$(command -v 7zz)"; HOST_PY="$(command -v python3)"
BASEPATH="/usr/bin:/bin:/usr/sbin:/sbin"   # what an app started from Finder gets
unmount() { mount | grep -qF " on $T/mnt " || return 0; hdiutil detach "$T/mnt" -quiet 2>/dev/null || hdiutil detach -force "$T/mnt" -quiet 2>/dev/null; }
trap 'unmount; chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }
expect() { # $1 = name, $2 = exit code, $3 = text the output contains ("" = anything)
  if [ "$RC" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$OUT"; }; then ok "$1"
  else fail "$1" "rc=$RC (want $2), want text: $3
$OUT"; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name" "failed: $*"; fi; }
[ -n "$HOST_7ZZ" ] && [ -n "$HOST_PY" ] || { echo "tests/app.sh needs 7zz and python3 (brew install sevenzip)" >&2; exit 1; }
. "$REPO/scripts/lib/shims.sh"   # SHIMS, SHIMS_VERSION

jget() { # $1 = JSON, $2 = dotted path → the value, "UNDEF" when missing, "OBJ" for an object or array
  /usr/bin/perl -MJSON::PP -e 'my $j = eval { decode_json($ARGV[0]) } or do { print "BADJSON"; exit };
    for my $k (split /\./, $ARGV[1]) { $j = ref $j eq "HASH" && exists $j->{$k} ? $j->{$k} : undef; last unless defined $j }
    print defined $j ? (ref $j ? "OBJ" : $j) : "UNDEF"' "$1" "$2"
}
in_sandbox() { # <command…> with a clean environment, the sandbox HOME and lock; sets OUT and RC
  OUT="$(cd / && env "${CLEAN_ENV[@]}" HOME="$H" REVIT_LOCK_DIR="$T/lock" REVIT_CX="$T/cx" PATH="${SB_PATH:-$BASEPATH}" "$@" 2>&1)"; RC=$?
}
fake_tool() { # $1 = folder, $2 = name, $3 = version line, $4 = exit code (default 0): records "<path> <args>" in $CALLS
  mkdir -p "$1"
  printf '#!/bin/bash\necho "$0 $*" >> "%s"\necho "%s"\nexit %s\n' "$CALLS" "$3" "${4:-0}" > "$1/$2"; chmod +x "$1/$2"
}
wrap_tool() { # $1 = path, $2 = host tool: logs the call, then runs the host tool (python3 and 7zz of a fixture bundle)
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\necho "$0 $*" >> "%s"\nexec "%s" "$@"\n' "$CALLS" "$2" > "$1"; chmod +x "$1"
}
repo_copy() { # the repo as git sees it (tracked and new files, working-tree content) in $R: a git repo with the shim tag
  chmod -R u+w "$R" 2>/dev/null; rm -rf "$R"; mkdir -p "$R" || exit 1
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
    | cpio -p0dm --quiet "$R") || { echo "repo copy failed"; exit 1; }
  mkdir -p "$R/app"
  printf "APP_NAME='Test App'\nAPP_BUNDLE_ID='io.example.testapp'\nAPP_MIN_MACOS=26.0\n" > "$R/app/app.conf"
  ( cd "$R" && git init -q && git add -A && git -c core.hooksPath=/dev/null -c user.name=test -c user.email=test \
      commit -qm fixture && git tag "v$SHIMS_VERSION" ) || { echo "repo copy: git failed"; exit 1; }
}
engine_files() { # the engine paths of the bundle (Global Constraints of the plan), NUL-separated, from $R
  (cd "$R" && git ls-files -z --cached --others --exclude-standard -- revit install.sh scripts tools installers/CHECKSUMS.txt LICENSE) \
    | tr '\0' '\n' | grep -vx -e scripts/get-toolchain.sh -e scripts/build-shims.sh -e scripts/build-release.sh | tr '\n' '\0'
}
fake_bundle() { # $1 = app path: the engine of $R, fake shims, fixture tools, the marker
  local app="$1" e="$1/Contents/Resources/engine" res="$1/Contents/Resources" s f
  chmod -R u+w "$app" 2>/dev/null; rm -rf "$app"; mkdir -p "$e" || exit 1
  (cd "$R" && engine_files | cpio -p0dm --quiet "$e")
  for s in "${SHIMS[@]}"; do mkdir -p "$e/build/$s"; echo "fake $s" > "$e/build/$s/$s.dll"; done
  echo "$SHIMS_VERSION" > "$e/build/.prebuilt"
  wrap_tool "$res/bin/7zz" "$HOST_7ZZ"; wrap_tool "$res/python/bin/python3" "$HOST_PY"
  fake_tool "$res/bin" cabextract "cabextract version 1.11"; fake_tool "$res/bin" winetricks "20260125 - sha256sum: 0"
  printf 'app_name=Test App\napp_version=0.0.1\n' > "$e/.app-bundle"
}
mkdir -p "$H/Applications" && : > "$CALLS" || exit 1; repo_copy

# ---- the marker and placement (Task 1) ----
for c in "ok:/Applications/Test App.app" "ok:/Applications/Utilities/Test App.app" "ok:$H/Applications/Test App.app" \
  "move:/Applications Old/Test App.app" "move:/ApplicationsX/Test App.app" "move:/Volumes/Test App/Test App.app" \
  "move:$H/Downloads/Test App.app" "move:/private/var/folders/xy/T/AppTranslocation/0A1B/d/Test App.app" \
  "move:$H/Applications Old/Test App.app"; do
  got="$(env "${CLEAN_ENV[@]}" HOME="$H" ROOT="$R" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; app_placement "$1"' _ "${c#*:}" 2>&1)"
  check "placement: ${c#*:} → ${c%%:*}" [ "$got" = "${c%%:*}" ]
done

fake_bundle "$A"
in_sandbox ROOT="$A/Contents/Resources/engine" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"
  echo "data=$DATA"; echo "bundled=$REVIT_BUNDLED"; echo "7zz=$(command -v 7zz)"; echo "py=$(command -v python3)"
  bash -c "echo child-data=\$REVIT_DATA"'
check "marker: DATA comes from the bundle" grep -qxF "data=$H/Library/Application Support/Test App" <<<"$OUT"
check "marker: REVIT_BUNDLED is 1" grep -qx "bundled=1" <<<"$OUT"
check "marker: 7zz and python3 come from the bundle" eval 'grep -qxF "7zz=$A/Contents/Resources/bin/7zz" <<<"$OUT" &&
  grep -qxF "py=$A/Contents/Resources/python/bin/python3" <<<"$OUT"'
check "marker: a child gets REVIT_DATA" grep -qxF "child-data=$H/Library/Application Support/Test App" <<<"$OUT"
in_sandbox ROOT="$A/Contents/Resources/engine" REVIT_DATA="$T/mine" REVIT_BUNDLED=0 /bin/bash -c '. "$ROOT/scripts/lib/common.sh"
  echo "data=$DATA"; echo "bundled=$REVIT_BUNDLED"'
check "marker: the caller's REVIT_DATA and REVIT_BUNDLED=0 win" eval 'grep -qxF "data=$T/mine" <<<"$OUT" && grep -qx "bundled=0" <<<"$OUT"'
in_sandbox ROOT="$A/Contents/Resources/engine" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/common.sh"; echo "$PATH"'
check "marker: PATH gets the bundle once" [ "$(tr ':' '\n' <<<"$OUT" | grep -cxF "$A/Contents/Resources/bin")" = 1 ]
mkdir -p "$T/brew0"; ln -sf "$HOST_7ZZ" "$T/brew0/7zz"; ln -sf "$HOST_PY" "$T/brew0/python3"
SB_PATH="$T/brew0:$A/Contents/Resources/bin:$A/Contents/Resources/python/bin:$BASEPATH" \
  in_sandbox ROOT="$A/Contents/Resources/engine" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; command -v 7zz; command -v python3'
check "marker: the bundle leads PATH even when it is already further down" \
  eval '[ "$OUT" = "$A/Contents/Resources/bin/7zz"$'"'"'\n'"'"'"$A/Contents/Resources/python/bin/python3" ]'

in_sandbox "$A/Contents/Resources/engine/revit" status --json
expect "status --json in the bundle" 0 ""
check "status --json: app block" eval '[ "$(jget "$OUT" app.name)" = "Test App" ] && [ "$(jget "$OUT" app.version)" = 0.0.1 ] &&
  [ "$(jget "$OUT" app.path)" = "$A" ] && [ "$(jget "$OUT" app.placement)" = ok ]'
check "status --json: app.data in the bundle" [ "$(jget "$OUT" app.data)" = "$H/Library/Application Support/Test App" ]
fake_bundle "$T/Test App.app"; in_sandbox "$T/Test App.app/Contents/Resources/engine/revit" status --json
check "status --json: an app outside Applications should move" [ "$(jget "$OUT" app.placement)" = move ]
in_sandbox "$R/revit" status --json
check "status --json: a clone has no app block" eval '[ "$(jget "$OUT" app)" = UNDEF ] && [ "$(jget "$OUT" bottles)" = OBJ ]'

# ---- fetching the pinned tools (Task 2): the refusals, offline ----
echo "not an archive" > "$TOP/fake.tar.xz"
FAKE_SUM="$(shasum -a 256 "$TOP/fake.tar.xz" | cut -d' ' -f1)"; ZEROS="$(printf '0%.0s' $(seq 1 64))"
sed -e "s|^SEVENZIP_URL=.*|SEVENZIP_URL=file://$TOP/fake.tar.xz|" -e "s|^SEVENZIP_SHA256=.*|SEVENZIP_SHA256=$ZEROS|" \
  "$R/app/tools.sh" > "$T/pins.sh" 2>/dev/null
in_sandbox "$R/app/fetch-tools.sh" "$T/out" "$T/pins.sh"
expect "fetch: a wrong checksum is refused" 1 "file://$TOP/fake.tar.xz"
check "fetch: the refusal names both sums" eval 'grep -qF "$ZEROS" <<<"$OUT" && grep -qF "$FAKE_SUM" <<<"$OUT"'
check "fetch: a refusal leaves no output and no .part" eval '[ ! -e "$T/out" ] && [ ! -e "$T/out.partial" ] &&
  [ -z "$(find "$R/dist/app-cache" -name "*.part" 2>/dev/null)" ]'
c="$(cd "$R" && git ls-files 'tools/shims/rvtfix/*.c' | head -1)"
echo "/* changed */" >> "$R/$c"; git -C "$R" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test commit -qam change
rm -rf "$R/dist/app-cache"; in_sandbox "$R/app/fetch-tools.sh" "$T/out"
expect "fetch: shim sources changed since the tag" 1 "shim sources changed since v$SHIMS_VERSION"
check "fetch: nothing downloaded before the shim check" [ -z "$(find "$R/dist/app-cache" -type f 2>/dev/null)" ]
repo_copy; git -C "$R" tag -d "v$SHIMS_VERSION" >/dev/null
in_sandbox "$R/app/fetch-tools.sh" "$T/out"; expect "fetch: no shim tag" 1 "no tag v$SHIMS_VERSION"
repo_copy

# ---- assembling the bundle (Task 3) ----
fixture_tools() { # $1 = folder: what app/fetch-tools.sh makes, with fixture content
  local d="$1" s l
  rm -rf "$d"; mkdir -p "$d/python/lib/python3.99" "$d/sources"
  wrap_tool "$d/bin/7zz" "$HOST_7ZZ"; wrap_tool "$d/python/bin/python3" "$HOST_PY"
  fake_tool "$d/bin" cabextract "cabextract version 1.11"
  # as the real one: a line naming the folder (digits in it) before the version
  printf '#!/bin/bash\necho "Executing cd /opt/Revit 2025/bin"\necho "20260125 - sha256sum: 0"\n' > "$d/bin/winetricks"; chmod +x "$d/bin/winetricks"
  echo 'X = 1' > "$d/python/lib/python3.99/m.py"
  for s in "${SHIMS[@]}"; do mkdir -p "$d/shims/$s"; echo "fake $s" > "$d/shims/$s/$s.dll"; done; echo MIT > "$d/shims/LICENSE"
  for l in 7-Zip cabextract winetricks Python; do mkdir -p "$d/licenses/$l"; echo "license of $l" > "$d/licenses/$l/LICENSE.txt"; done
  echo src > "$d/sources/7z2604-src.tar.xz"; echo src > "$d/sources/cabextract-1.11.tar.gz"
}
printf '#!/bin/bash\n' > "$T/stub"; chmod +x "$T/stub"
TOOLS="$T/tools"; fixture_tools "$TOOLS"
mkzip() { "$HOST_PY" -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w")
for a in sys.argv[2:]: n, c = a.split("=", 1); z.writestr(n, c)
z.close()' "$@"; }
mkdir -p "$T/ci"; mkzip "$T/ci/Create_Installer_RVT_2025_5_English_WIN64.exe" \
  "collection.xml=<C><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2025_B_002_002.7z</BrowserImageUrl></C>"
mkdir -p "$T/cx/bin"; for x in cxbottle wineserver; do printf '#!/bin/bash\nexit 0\n' > "$T/cx/bin/$x"; chmod +x "$T/cx/bin/$x"; done
listing() { find "$1" -exec stat -f '%N %z %m' {} + | sort; }

B="$T/out/Test App.app"; E="$B/Contents/Resources/engine"; RS="$B/Contents/Resources"
in_sandbox "$R/app/make-bundle.sh" "$B" "$T/stub" "$TOOLS" 0.0.1
expect "bundle: make-bundle.sh assembles the app" 0 ""
miss=""; for f in "Contents/MacOS/Test App" Contents/Info.plist Contents/Resources/engine/tools/installer_source.py \
  Contents/Resources/engine/installers/CHECKSUMS.txt Contents/Resources/engine/LICENSE Contents/Resources/bin/7zz \
  Contents/Resources/python/bin/python3 Contents/Resources/Licenses/README.txt Contents/Resources/Licenses/revit-macos/LICENSE \
  Contents/Resources/Licenses/Python/LICENSE.txt Contents/Resources/engine/build/LICENSE; do [ -e "$B/$f" ] || miss+=" $f"; done
check "bundle: layout" [ -z "$miss" ]
miss=""; for f in revit install.sh scripts/run-steps.sh scripts/check-bundle.sh; do [ -x "$E/$f" ] || miss+=" $f"; done
check "bundle: engine scripts stay executable" [ -z "$miss" ]
extra=""; for f in tests docs .git internal app scripts/get-toolchain.sh scripts/build-shims.sh scripts/build-release.sh; do
  [ ! -e "$E/$f" ] || extra+=" $f"; done
check "bundle: no tests, docs, git, app sources or dev-only scripts" [ -z "$extra" ]
check "bundle: the shims are release v$SHIMS_VERSION" eval '[ "$(cat "$E/build/.prebuilt")" = "$SHIMS_VERSION" ] && [ -f "$E/build/rvtfix/rvtfix.dll" ]'
check "bundle: the marker names the app and the tools" eval 'grep -qx "app_name=Test App" "$E/.app-bundle" &&
  grep -qx "app_version=0.0.1" "$E/.app-bundle" && grep -qx "sevenzip=26.04" "$E/.app-bundle" && grep -qx "shims=$SHIMS_VERSION" "$E/.app-bundle"'
check "bundle: Licenses/README.txt names every component" eval 'for c in 7-Zip cabextract winetricks Python revit-macos; do
  grep -q "$c" "$RS/Licenses/README.txt" || exit 1; done'
pl() { plutil -extract "$1" raw -o - "$B/Contents/Info.plist" 2>/dev/null; }
check "bundle: Info.plist" eval '[ "$(pl CFBundleIdentifier)" = io.example.testapp ] && [ "$(pl CFBundleExecutable)" = "Test App" ] &&
  [ "$(pl CFBundleName)" = "Test App" ] && [ "$(pl CFBundleShortVersionString)" = 0.0.1 ] && [ "$(pl LSMinimumSystemVersion)" = 26.0 ] &&
  [ "$(pl LSUIElement)" = true ]'
pyc="$(find "$RS/python/lib/python3.99/__pycache__" -name 'm.*.pyc' 2>/dev/null | head -1)"
check "bundle: Python bytecode is unchecked-hash" eval '[ -n "$pyc" ] && [ "$(od -An -tu4 -j4 -N4 "$pyc" | tr -d " ")" = 1 ]'
in_sandbox "$R/app/make-bundle.sh" "$T/out/V.app" "$T/stub" "$TOOLS" 1.2;  expect "bundle: refuses version 1.2" 2 "X.Y.Z"
in_sandbox "$R/app/make-bundle.sh" "$B" "$T/stub" "$TOOLS" 0.0.2;           expect "bundle: refuses an existing output" 2 "exists"
cp -R "$TOOLS" "$T/tools-noshim"; rm -rf "$T/tools-noshim/shims/wbemshim"
in_sandbox "$R/app/make-bundle.sh" "$T/out/S.app" "$T/stub" "$T/tools-noshim" 0.0.1; expect "bundle: refuses an incomplete shim set" 2 "shims"
check "bundle: a refusal leaves nothing behind" eval '[ -z "$(find "$T/out" -maxdepth 1 -name "*.partial")" ] && [ ! -e "$T/out/S.app" ] && [ ! -e "$T/out/V.app" ]'

fake_bundle() { # $1 = app path: from here on, the real assembly with the fixture tools; $2 = tools (default $TOOLS)
  chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"
  (cd / && env "${CLEAN_ENV[@]}" PATH="$BASEPATH" "$R/app/make-bundle.sh" "$1" "$T/stub" "${2:-$TOOLS}" 0.0.1 >/dev/null) \
    || { echo "make-bundle failed for $1"; exit 1; }
}
AE="$A/Contents/Resources/engine"
fake_bundle "$A"; chmod -R a-w "$A"
touch "$T/before-doctor"; sleep 1; in_sandbox "$AE/revit" doctor 2025
check "read-only bundle: doctor runs and writes nothing" eval 'grep -qE "\([0-9]+ checks\)$" <<<"$OUT" &&
  [ -z "$(find "$A" "$H" -newer "$T/before-doctor" 2>/dev/null)" ]'
only_under() { # $1 = folder, $2 = stamp: every path in $H newer than $2 is in $1 or a folder on the way to it
  local p
  while IFS= read -r p; do
    case "$1/" in "$p"/*) continue ;; esac
    case "$p" in "$1"|"$1"/*) ;; *) return 1 ;; esac
  done < <(find "$H" -newer "$2" 2>/dev/null)
}
AD="$H/Library/Application Support/Test App"
touch "$T/before-report"; sleep 1; in_sandbox "$AE/revit" report 2025
check "read-only bundle: report writes its folder in the app's data folder only" eval '[ "$RC" = 0 ] &&
  [ -s "$(ls -d "$AD/logs/rvt2025-a/"*-report 2>/dev/null | head -1)/report.zip" ] &&
  [ -z "$(find "$A" -newer "$T/before-report" 2>/dev/null)" ] && only_under "$AD/logs/rvt2025-a" "$T/before-report"'
[ "$RC" = 0 ] || printf '%s\n' "$OUT" | head -5 | sed 's/^/     /'
: > "$CALLS"; in_sandbox "$AE/scripts/check-bundle.sh"
expect "read-only bundle: check-bundle passes" 0 ""
check "check-bundle: five ok lines" [ "$(grep -c '^ok ' <<<"$OUT")" = 5 ]
check "check-bundle: names each tool's version" eval 'grep -q "^ok   winetricks 20260125 (" <<<"$OUT" &&
  grep -q "^ok   cabextract 1.11 (" <<<"$OUT" && grep -qE "^ok   python3 [0-9]+\.[0-9]+\.[0-9]+ \(" <<<"$OUT"'
check "check-bundle: every tool from the bundle" eval 'for t in 7zz cabextract winetricks python3; do
  grep "^ok   $t " <<<"$OUT" | grep -qF "($A/Contents/Resources/" || exit 1; done'
cp -R "$TOOLS" "$T/tools-nohash"
printf '#!/bin/bash\ncase "$*" in *_hashlib*) exit 1 ;; esac\nexec "%s" "$@"\n' "$HOST_PY" > "$T/tools-nohash/python/bin/python3"
fake_bundle "$T/nohash/Test App.app" "$T/tools-nohash"; in_sandbox "$T/nohash/Test App.app/Contents/Resources/engine/scripts/check-bundle.sh"
expect "check-bundle: a broken _hashlib fails it" 1 "FAIL python3"
in_sandbox "$R/scripts/check-bundle.sh"; expect "check-bundle: outside the app" 1 "not inside the app"

mkdir -p "$T/brew"; for x in 7zz python3 cabextract winetricks; do fake_tool "$T/brew" "$x" "brew $x" 1; done
: > "$CALLS"; SB_PATH="$T/brew:$BASEPATH" in_sandbox "$AE/scripts/check-bundle.sh"; rc1=$RC
SB_PATH="$T/brew:$BASEPATH" in_sandbox "$AE/revit" find-installer "$T/ci" --json
check "bundle tools win over PATH: check-bundle and find-installer work" eval '[ "$rc1" = 0 ] && [ "$RC" = 0 ] &&
  [ "$(jget "$OUT" year)" = 2025 ] && [ "$(jget "$OUT" kind)" = create-installer ]'
check "bundle tools win over PATH: Python and its 7zz are the bundle's" eval 'grep -qF "$A/Contents/Resources/python/bin/python3 " "$CALLS" &&
  grep -qF "$A/Contents/Resources/bin/7zz x" "$CALLS" && ! grep -qF "$T/brew/" "$CALLS"'

in_sandbox REVIT_DATA="$T/data" "$AE/revit" check 2025; o1="${OUT//$AE/<root>}"; r1=$RC
SB_PATH="$TOOLS/bin:$TOOLS/python/bin:$BASEPATH" in_sandbox REVIT_DATA="$T/data" "$R/revit" check 2025; o2="${OUT//$R/<root>}"; r2=$RC
check "read-only bundle: revit check equals the clone" eval '[ "$r1" = "$r2" ] && [ "$o1" = "$o2" ]'
[ "$o1" = "$o2" ] || diff <(echo "$o1") <(echo "$o2") | head -10 | sed 's/^/     /'
in_sandbox "$AE/revit" check 2025
check "read-only bundle: data goes to Application Support" [ -n "$(find "$H/Library/Application Support/Test App/logs/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]
mkdir -p "$T/rec"; for x in git curl clang; do fake_tool "$T/rec" "$x" "" 1; done
: > "$CALLS"; SB_PATH="$T/rec:$BASEPATH" in_sandbox "$AE/scripts/get-shims.sh"
expect "read-only bundle: get-shims takes the bundled shims" 0 "prebuilt shims v$SHIMS_VERSION"
check "read-only bundle: get-shims calls no git, curl or compiler" eval '! grep -qF "$T/rec/" "$CALLS"'

IB="$T/inc/Test App.app"; fake_bundle "$IB"; rm -rf "$IB/Contents/Resources/engine/build/wbemshim"; chmod -R a-w "$IB"
: > "$CALLS"; SB_PATH="$T/rec:$BASEPATH" in_sandbox "$IB/Contents/Resources/engine/scripts/check-bundle.sh"
expect "read-only bundle: an incomplete shim set fails check-bundle" 1 "FAIL shims"
SB_PATH="$T/rec:$BASEPATH" in_sandbox "$IB/Contents/Resources/engine/scripts/get-shims.sh"
expect "read-only bundle: an incomplete shim set fails get-shims" 1 "not release v"
check "read-only bundle: an incomplete shim set downloads nothing" eval '! grep -qF "$T/rec/" "$CALLS"'

WB="$T/w/Test App.app"; WE="$WB/Contents/Resources/engine"; fake_bundle "$WB"; before="$(listing "$WB")"
rcs=""
in_sandbox "$WE/scripts/check-bundle.sh";                 rcs+="$RC "
in_sandbox "$WE/revit" status --json;                     rcs+="$RC "
in_sandbox "$WE/revit" check 2025;                        rcs+="$RC "
in_sandbox "$WE/revit" find-installer "$T/ci" --json;     rcs+="$RC "
in_sandbox "$WE/revit" addins list 2025 --json;           rcs+="$RC "
in_sandbox "$WE/scripts/get-shims.sh";                    rcs+="$RC "
# doctor exits 0 or 1 by what this Mac has; that it ran shows in its last line ("… (N checks)") and in valid JSON
in_sandbox "$WE/revit" doctor;                            dr1="$RC $(tail -1 <<<"$OUT" | grep -cE '\([0-9]+ checks\)$')"
in_sandbox "$WE/revit" doctor 2025 --json;                dr2="$RC $(jget "$OUT" summary.checks | grep -cE '^[0-9]+$')"
# each ran as it should (check 2025 stops at its preflight, as the read-only run above): the listing below means something
check "writable bundle: the engine commands ran" [ "$rcs" = "0 0 $r1 0 0 0 " ]
check "writable bundle: doctor ran, with and without a year" eval 'case "$dr1|$dr2" in [01]" 1|1 1") true ;; *) false ;; esac'
check "writable bundle: running the engine changes nothing in it" [ "$before" = "$(listing "$WB")" ]
[ "$before" = "$(listing "$WB")" ] || diff <(echo "$before") <(listing "$WB") | head -10 | sed 's/^/     /'

QB="$T/q/Test App.app"; fake_bundle "$QB"; xattr -w com.apple.quarantine '0081;00000000;Safari;' "$QB/Contents/Resources/engine/scripts/ps2pdf-port.sh"
in_sandbox ROOT="$QB/Contents/Resources/engine" /bin/bash -c '. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/steps/fixes.sh"; pdf_port_script'
check "PDF helper copy has not the app's quarantine" eval '[ "$OUT" = "$H/Library/Application Support/Test App/libexec/ps2pdf-port.sh" ] &&
  ! { xattr -p com.apple.quarantine "$OUT" 2>/dev/null | grep -q Safari; }'   # a quarantine-enabled caller stamps its own

# ---- signing and the DMG (Task 4): real Mach-O files, no symlink out of the bundle ----
echo 'int main(void) { return 0; }' > "$T/main.c"; echo 'int f(void) { return 1; }' > "$T/lib.c"
cc_() { /usr/bin/cc -mmacosx-version-min="$1" "${@:2}" 2>/dev/null; }   # $1 = minimum macOS, rest = cc arguments
sign_tools() { # $1 = folder, $2 = minimum macOS of _x.so, $3 = of 7zz's x86_64 slice (both default 14.0)
  local d="$1" s l
  rm -rf "$d"; mkdir -p "$d/bin" "$d/python/bin" "$d/python/lib/python3.99/lib-dynload" "$d/sources"
  cc_ 14.0 -arch arm64 -o "$d/7zz-arm64" "$T/main.c" && cc_ "${3:-14.0}" -arch x86_64 -o "$d/7zz-x86_64" "$T/main.c" \
    && lipo -create -output "$d/bin/7zz" "$d/7zz-arm64" "$d/7zz-x86_64" && rm "$d/7zz-arm64" "$d/7zz-x86_64" || return 1
  cc_ 14.0 -arch arm64 -o "$d/python/bin/python3.99" "$T/main.c" && ln -s python3.99 "$d/python/bin/python3" || return 1
  cc_ "${2:-14.0}" -arch arm64 -bundle -o "$d/python/lib/python3.99/lib-dynload/_x.so" "$T/lib.c" || return 1
  cc_ 14.0 -arch arm64 -dynamiclib -o "$d/python/lib/libpython3.99.dylib" "$T/lib.c" || return 1
  cc_ 14.0 -arch arm64 -c -o "$d/python/lib/x.o" "$T/lib.c" && ar rcs "$d/python/lib/libx.a" "$d/python/lib/x.o" 2>/dev/null || return 1
  fake_tool "$d/bin" cabextract "cabextract version 1.11"; fake_tool "$d/bin" winetricks "20260125 - sha256sum: 0"
  for s in "${SHIMS[@]}"; do mkdir -p "$d/shims/$s"; echo "fake $s" > "$d/shims/$s/$s.dll"; done; echo MIT > "$d/shims/LICENSE"
  for l in 7-Zip cabextract winetricks Python; do mkdir -p "$d/licenses/$l"; echo "license of $l" > "$d/licenses/$l/LICENSE.txt"; done
}
cc_ 14.0 -arch arm64 -o "$T/stub-bin" "$T/main.c"
sign_bundle() { # $1 = app path, $2 = tools folder: assembled with the Mach-O stub
  chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"
  (cd / && env "${CLEAN_ENV[@]}" PATH="$BASEPATH" "$R/app/make-bundle.sh" "$1" "$T/stub-bin" "$2" 0.0.1 >/dev/null)
}
SB="$T/s/Test App.app"
if sign_tools "$T/stools" && sign_bundle "$SB" "$T/stools"; then
  in_sandbox "$R/app/sign.sh" "$SB" 26.0 "$T/inv.txt"
  expect "sign: sign.sh signs the app" 0 ""
  TAB=$'\t'
  check "sign: the inventory holds the 5 images, not the archive or the object" eval '[ "$(wc -l < "$T/inv.txt" | tr -d " ")" = 5 ] &&
    grep -q "^Contents/MacOS/Test App$TAB" "$T/inv.txt" && grep -qx "Contents/Resources/bin/7zz${TAB}x86_64 arm64" "$T/inv.txt" &&
    grep -q "_x.so" "$T/inv.txt" && grep -q "libpython3.99.dylib" "$T/inv.txt" && grep -q "python3.99$TAB" "$T/inv.txt" &&
    ! grep -q -e "x.o" -e "libx.a" "$T/inv.txt"'
  adhoc=1; while IFS="$TAB" read -r p _; do d="$(codesign -dv "$SB/$p" 2>&1)"; grep -q "Signature=adhoc" <<<"$d" || adhoc=0; done < "$T/inv.txt"
  check "sign: every image is signed ad hoc" eval '[ "$adhoc" = 1 ] && [ -s "$T/inv.txt" ]'
  check "sign: the app verifies --deep --strict" codesign --verify --strict --deep "$SB"
  ditto "$SB" "$T/s2/Test App.app"; printf '#' >> "$T/s2/Test App.app/Contents/Resources/engine/revit"
  check "sign: a changed engine file breaks the seal" eval 'codesign --verify --strict --deep "$SB" 2>/dev/null && ! codesign --verify --strict --deep "$T/s2/Test App.app" 2>/dev/null'
  sign_tools "$T/stools15" 15.0 && sign_bundle "$T/s3/Test App.app" "$T/stools15"
  in_sandbox "$R/app/sign.sh" "$T/s3/Test App.app" 14.0
  check "sign: a Mach-O newer than the minimum macOS is refused" eval '[ "$RC" = 1 ] && grep -q "_x.so" <<<"$OUT" &&
    grep -q "15.0" <<<"$OUT" && grep -q "14.0" <<<"$OUT"'
  sign_tools "$T/stools7" 14.0 15.0 && sign_bundle "$T/s4/Test App.app" "$T/stools7"
  in_sandbox "$R/app/sign.sh" "$T/s4/Test App.app" 14.0
  check "sign: a newer slice of a universal file is refused" eval '[ "$RC" = 1 ] && grep -q "7zz" <<<"$OUT" && grep -q "x86_64" <<<"$OUT"'

  in_sandbox "$R/app/make-dmg.sh" "$SB" "$T/t.dmg"
  expect "dmg: make-dmg.sh makes the DMG" 0 ""
  mkdir -p "$T/mnt"
  if hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$T/mnt" "$T/t.dmg" >/dev/null 2>&1; then
    check "dmg: the app and an Applications link" eval '[ -d "$T/mnt/Test App.app" ] && [ "$(readlink "$T/mnt/Applications")" = /Applications ]'
    check "dmg: the app on the DMG verifies" codesign --verify --strict --deep "$T/mnt/Test App.app"
    check "dmg: it is read-only" eval '! touch "$T/mnt/x" 2>/dev/null'
    unmount
  else fail "dmg: hdiutil attach" "$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$T/mnt" "$T/t.dmg" 2>&1)"; fi
  check "dmg: the .sha256 checks out" eval '(cd "$T" && shasum -a 256 -c t.dmg.sha256 >/dev/null)'
else fail "sign: fixture" "cc, lipo, ar or make-bundle failed"; fi

echo "$((n - fails))/$n passed"
[ "$fails" = 0 ]
