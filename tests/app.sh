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
trap 'chmod -R u+w "$TOP" 2>/dev/null; rm -rf "$TOP"' EXIT
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
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexec "%s" "$@"\n' "$1" "$CALLS" "$2" > "$1"; chmod +x "$1"
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
: > "$CALLS"; mkdir -p "$H/Applications"; repo_copy

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

in_sandbox "$A/Contents/Resources/engine/revit" status --json
expect "status --json in the bundle" 0 ""
check "status --json: app block" eval '[ "$(jget "$OUT" app.name)" = "Test App" ] && [ "$(jget "$OUT" app.version)" = 0.0.1 ] &&
  [ "$(jget "$OUT" app.path)" = "$A" ] && [ "$(jget "$OUT" app.placement)" = ok ]'
fake_bundle "$T/Test App.app"; in_sandbox "$T/Test App.app/Contents/Resources/engine/revit" status --json
check "status --json: an app outside Applications should move" [ "$(jget "$OUT" app.placement)" = move ]
in_sandbox "$R/revit" status --json
check "status --json: a clone has no app block" eval '[ "$(jget "$OUT" app)" = UNDEF ] && [ "$(jget "$OUT" bottles)" = OBJ ]'

echo "$((n - fails))/$n passed"
[ "$fails" = 0 ]
