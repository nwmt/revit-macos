#!/usr/bin/env bash
# Tests for scripts/build-shims.sh, get-shims.sh and build-release.sh in a sandbox: a copy of the repo with a fake
# compiler (it records its arguments and writes its -o file), a fake curl (it "downloads" $FAKE_ZIP) and a
# get-toolchain.sh that only records the call.
# Runs under /bin/bash 3.2. Nothing real is touched, nothing is downloaded. Usage: tests/shims.sh
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }
TOP="$(cd "$TMP" && pwd -P)" || exit 1
T="$TOP/sand box"; R="$T/repo"; CALLS="$T/calls"   # a space in every path
CCF="$R/toolchain/llvm-mingw/bin/x86_64-w64-mingw32-clang"
trap 'rm -rf "$TOP"' EXIT
n=0; fails=0
ok()   { n=$((n + 1)); echo "ok   $1"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/     /'; }
expect() { # $1 = name, $2 = exit code, $3 = text the output contains ("" = anything)
  if [ "$RC" = "$2" ] && { [ -z "$3" ] || grep -qF -- "$3" <<<"$OUT"; }; then ok "$1"
  else fail "$1" "rc=$RC (want $2), want text: $3
$OUT"; fi
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name" "failed: $*"; fi; }
called() { grep -qF -- "$1" "$CALLS"; }
absent() { ! grep -qF -- "$1" "$CALLS"; }

reset() { # a fresh sandbox; $1 = nocc: no compiler. get-toolchain.sh records the call and succeeds only with a compiler
  rm -rf "$T"; mkdir -p "$R" "$T/home" || { echo "sandbox setup failed"; exit 1; }
  cp -R "$REPO/scripts" "$REPO/tools" "$REPO/LICENSE" "$R/"; : > "$CALLS"
  printf '#!/bin/bash\necho get-toolchain >> "%s"\n[ -x "%s" ]\n' "$CALLS" "$CCF" > "$R/scripts/get-toolchain.sh"
  mkdir -p "$R/toolchain/vulkan-headers/include/vulkan" "$T/bin"; touch "$R/toolchain/vulkan-headers/include/vulkan/vulkan.h"
  cat > "$T/bin/curl" <<EOF
#!/bin/bash
# fake curl: records the call and "downloads" \$FAKE_ZIP into the -o file; fails without it
echo curl >> "$CALLS"
o=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && o="\$2"; shift; done
[ -n "\${FAKE_ZIP:-}" ] && cp "\$FAKE_ZIP" "\$o"
EOF
  chmod +x "$T/bin/curl"
  [ "${1:-}" = nocc ] && return 0
  mkdir -p "$(dirname "$CCF")"
  cat > "$CCF" <<EOF
#!/bin/bash
# fake clang: records its arguments and writes "fake <file name>" into the -o file; fails when FAKE_CC_FAIL is set
{ printf 'cc'; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >> "$CALLS"
[ -z "\${FAKE_CC_FAIL:-}" ] || exit 1
o=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && o="\$2"; shift; done
echo "fake \$(basename "\$o")" > "\$o"
EOF
  chmod +x "$CCF"
}
run() { OUT="$(cd / && env -u SHIMS_FROM_SOURCE -u RUN_DIR -u FAKE_ZIP HOME="$T/home" PATH="$T/bin:$PATH" "$@" 2>&1)"; RC=$?; }
ALL="d3dwp/d3dwp.dll ncryptshim/ncrypt.dll pdfprinter/add_printer.exe rvtfix/rvtfix.dll svcshim/svcshim.exe tlbpin/msls31.dll vkshim/vulkan-1.dll wbemshim/wbemshim.dll wv2fix/version.dll"
V="$(sed -n 's/^SHIMS_VERSION=//p' "$REPO/scripts/lib/shims.sh")"   # the pinned version: the tests follow the pin
OLD="d3dwp/d3dwp.dll ncrypt-shim/ncrypt.dll pdf-printer/add_printer.exe rvtfix/rvtfix.dll svcshim/svcshim.exe tlbpin/msls31.dll vkshim/vulkan-1.dll wbem-shim/wbemshim.dll wv2fix/version.dll"
mkzip() { # $1 = zip, rest = shim files (as in ALL/OLD): a release package with build/LICENSE and build/<file> "release <name>"
  local z="$1" d="$T/zipsrc" f list="build/LICENSE"; shift; rm -rf "$d"; mkdir -p "$d/build"; echo license > "$d/build/LICENSE"
  for f in "$@"; do mkdir -p "$d/build/$(dirname "$f")"; echo "release $(basename "$f")" > "$d/build/$f"; list="$list build/$f"; done
  (cd "$d" && zip -q -X "$z" $list)
}
pin_zip() { sed -i '' "s/^SHIMS_SHA256=.*/SHIMS_SHA256=$(shasum -a 256 "$1" | cut -d' ' -f1)/" "$R/scripts/lib/shims.sh"; }
fill_release() { # rest = shim files: build/ as get-shims.sh leaves it after unpacking release $V
  local f; mkdir -p "$R/build"; echo "$V" > "$R/build/.prebuilt"; echo license > "$R/build/LICENSE"
  for f in "$@"; do mkdir -p "$R/build/$(dirname "$f")"; echo "release $(basename "$f")" > "$R/build/$f"; done
}

# ---- build-shims.sh ----
reset; run "$R/scripts/build-shims.sh" rvtfix
expect "build-shims builds one shim" 0 "built: build/rvtfix/rvtfix.dll"
check "rvtfix: common headers, no timestamp, built in .new/ under its own name, its source and libraries" \
  called "[-I$R/tools/shims/common] [-Wl,--no-insert-timestamp] [-o] [$R/build/rvtfix/.new/rvtfix.dll] [$R/tools/shims/rvtfix/rvtfix.c] [-luser32] [-lole32]"
check "rvtfix: moved into build/rvtfix/, no .new left" test "$(cat "$R/build/rvtfix/rvtfix.dll")" = "fake rvtfix.dll" -a ! -e "$R/build/rvtfix/.new"
reset; run "$R/scripts/build-shims.sh" ncryptshim
expect "ncryptshim builds" 0 "built: build/ncryptshim/ncrypt.dll"
check "ncryptshim: generated sources in build/, none in tools/" test -f "$R/build/ncryptshim/gen/forwards.S" -a ! -e "$R/tools/shims/ncryptshim/forwards.S"
check "ncryptshim: sources in the old order" \
  called "[$R/tools/shims/ncryptshim/ncrypt_shim.c] [$R/build/ncryptshim/gen/forwards_table.c] [$R/build/ncryptshim/gen/forwards.S] [$R/build/ncryptshim/gen/ncrypt.def] [-lbcrypt] [-Wl,--enable-stdcall-fixup]"
reset; run "$R/scripts/build-shims.sh"
expect "build-shims without names builds every shim" 0 "built: build/wv2fix/version.dll"
miss=""; for f in $ALL; do [ -f "$R/build/$f" ] || miss+=" $f"; done
check "every shim's file (missing:$miss)" test -z "$miss"
check "vkshim: Vulkan headers from toolchain/" called "[-I$R/toolchain/vulkan-headers/include]"
reset; fill_release $ALL; run "$R/scripts/build-shims.sh" rvtfix
expect "a local build over a release" 0 "built: build/rvtfix/rvtfix.dll"; check "a local build drops the release marker" test ! -e "$R/build/.prebuilt"
reset; mkdir -p "$R/build/svcshim"; echo good > "$R/build/svcshim/svcshim.exe"
run env FAKE_CC_FAIL=1 "$R/scripts/build-shims.sh" svcshim
expect "a failed build fails" 1 "svcshim"
check "a failed build keeps the last good file" grep -qx good "$R/build/svcshim/svcshim.exe"
reset; run "$R/scripts/build-shims.sh" rvtfix nonsense
expect "an unknown shim is refused before anything is built" 2 "Unknown shim: nonsense"; check "unknown shim: nothing built" test ! -s "$CALLS"
# no compiler: get-shims.sh decides first (sources, layout, marker); the pinned release that fits is used as it is
reset nocc; fill_release $ALL; run "$R/scripts/build-shims.sh" wv2fix
expect "no compiler: the pinned release's file" 0 "prebuilt v$V: build/wv2fix/version.dll"
check "no compiler: nothing fetched" absent get-toolchain; check "no compiler: nothing downloaded" absent curl
# a marker of another release: its files are not used; get-shims.sh brings the pinned one
reset nocc; mkdir -p "$R/build/wv2fix"; echo 0.0.1 > "$R/build/.prebuilt"; echo stale > "$R/build/wv2fix/version.dll"
mkzip "$T/new.zip" $ALL; pin_zip "$T/new.zip"; run env FAKE_ZIP="$T/new.zip" "$R/scripts/build-shims.sh" wv2fix
expect "stale marker: the pinned release is downloaded" 0 "prebuilt v$V: build/wv2fix/version.dll"
check "stale marker: the file is the pinned release's" grep -qx "release version.dll" "$R/build/wv2fix/version.dll"

# ---- get-shims.sh ----
reset nocc; mkdir -p "$R/build/ncrypt-shim" "$R/build/rvtfix"; echo "$V" > "$R/build/.prebuilt"
touch "$R/build/LICENSE" "$R/build/ncrypt-shim/ncrypt.dll" "$R/build/rvtfix/rvtfix.dll"
run env SHIMS_FROM_SOURCE=1 "$R/scripts/get-shims.sh"
expect "get-shims: building from source fetches the compiler" 1 "building from source"; check "from source: get-toolchain" called get-toolchain
check "from source: the release marker is gone" test ! -e "$R/build/.prebuilt"
check "from source: the release files are gone, new and old layout" test ! -e "$R/build/ncrypt-shim/ncrypt.dll" -a ! -e "$R/build/rvtfix/rvtfix.dll" -a ! -e "$R/build/LICENSE"
reset nocc; mkzip "$T/new.zip" $ALL; pin_zip "$T/new.zip"; run env FAKE_ZIP="$T/new.zip" "$R/scripts/get-shims.sh"
expect "get-shims: a release of this layout" 0 "prebuilt shims v$V in build/"
check "this layout: marker set" grep -qx "$V" "$R/build/.prebuilt"
run "$R/scripts/build-shims.sh"; expect "then build-shims takes all nine without a compiler" 0 "prebuilt v$V: build/wv2fix/version.dll"
check "then: nothing fetched" absent get-toolchain
reset nocc; mkzip "$T/old.zip" $OLD; pin_zip "$T/old.zip"; run env FAKE_ZIP="$T/old.zip" "$R/scripts/get-shims.sh"
expect "get-shims: a release of the old layout is refused (no git history)" 1 "does not hold every shim"
check "old layout: no marker, no files" test ! -e "$R/build/.prebuilt" -a ! -e "$R/build/ncrypt-shim/ncrypt.dll"
# files built earlier under the three new names must not complete an old package: the package is checked on its own
reset nocc; for f in ncryptshim/ncrypt.dll pdfprinter/add_printer.exe wbemshim/wbemshim.dll; do mkdir -p "$R/build/$(dirname "$f")"; echo built > "$R/build/$f"; done
mkzip "$T/old.zip" $OLD; pin_zip "$T/old.zip"; run env FAKE_ZIP="$T/old.zip" "$R/scripts/get-shims.sh"
expect "an old package next to files built earlier: refused" 1 "does not hold every shim"
check "old package next to built files: no marker, no old wv2fix" test ! -e "$R/build/.prebuilt" -a ! -e "$R/build/wv2fix/version.dll"
# the v0.5.0 package (old folders) in build/ with the pinned marker, and as the pinned download: none of its files is
# used, also not wv2fix/version.dll, whose folder kept its name
reset nocc; fill_release $OLD; mkzip "$T/old.zip" $OLD; pin_zip "$T/old.zip"
run env FAKE_ZIP="$T/old.zip" "$R/scripts/build-shims.sh" wv2fix
expect "old layout: refused, the compiler is fetched" 1 "does not hold every shim"; check "old layout: get-toolchain" called get-toolchain
check "old layout: its files and marker are gone" test ! -e "$R/build/wv2fix/version.dll" -a ! -e "$R/build/ncrypt-shim/ncrypt.dll" -a ! -e "$R/build/.prebuilt"
# an old cache that local builds made complete (three new names built with the compiler, then no compiler)
reset; fill_release $OLD; mkzip "$T/old.zip" $OLD; pin_zip "$T/old.zip"
run "$R/scripts/build-shims.sh" ncryptshim pdfprinter wbemshim; rm -f "$CCF"
run env FAKE_ZIP="$T/old.zip" "$R/scripts/build-shims.sh" wv2fix
expect "old cache completed by local builds: not taken" 1 "does not hold every shim"
check "completed old cache: its wv2fix is gone" test ! -e "$R/build/wv2fix/version.dll"
# the release/pin transition, as git sees it, with versions of its own: tag v1.0.0 on the old sources, the new
# sources, tag v1.1.0 on them, the pin commit. Every setup command must succeed, or the checks would take the
# no-history path
gitc() { git -C "$R" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null "$@"; }
reset nocc; sed -i '' 's/^SHIMS_VERSION=.*/SHIMS_VERSION=1.0.0/' "$R/scripts/lib/shims.sh"
if echo '/* old */' >> "$R/tools/shims/svcshim/svcshim.c" && gitc -c init.defaultBranch=main init -q && gitc add -A &&
   gitc commit -qm old && gitc tag v1.0.0 && cp "$REPO/tools/shims/svcshim/svcshim.c" "$R/tools/shims/svcshim/svcshim.c" &&
   gitc commit -qam new; then ok "sandbox git: tag v1.0.0 on the old sources, the new commit"; else fail "sandbox git: old and new commits"; fi
run "$R/scripts/get-shims.sh"; expect "before the pin: sources differ from v1.0.0, from source" 1 "shim sources changed since v1.0.0"
mkzip "$T/new.zip" $ALL
if gitc tag v1.1.0 && pin_zip "$T/new.zip" && sed -i '' 's/^SHIMS_VERSION=.*/SHIMS_VERSION=1.1.0/' "$R/scripts/lib/shims.sh" &&
   gitc commit -qam pin && [ "$(gitc rev-parse 'v1.1.0^{commit}')" = "$(gitc rev-parse HEAD~1)" ] &&
   [ "$(gitc log -1 --format=%s)" = pin ]; then ok "sandbox git: tag v1.1.0 on the new sources, then the pin"
else fail "sandbox git: tag v1.1.0 and the pin"; fi
: > "$CALLS"; run env FAKE_ZIP="$T/new.zip" "$R/scripts/get-shims.sh"
expect "after the pin: v1.1.0 is downloaded, no source build" 0 "prebuilt shims v1.1.0 in build/"; check "after the pin: no compiler" absent get-toolchain
run "$R/scripts/get-shims.sh"; expect "after the pin, again: already there" 0 "prebuilt shims v1.1.0 already in build/"

# ---- build-release.sh ----
reset; run "$R/scripts/build-release.sh" 9.9.9
expect "build-release packs the shims" 0 "revit-macos-shims-9.9.9.zip"
check "release zip: LICENSE and exactly the nine shim files" test "$(unzip -Z1 "$R/dist/revit-macos-shims-9.9.9.zip" | tr '\n' ' ')" = \
  "build/LICENSE build/d3dwp/d3dwp.dll build/ncryptshim/ncrypt.dll build/pdfprinter/add_printer.exe build/rvtfix/rvtfix.dll build/svcshim/svcshim.exe build/tlbpin/msls31.dll build/vkshim/vulkan-1.dll build/wbemshim/wbemshim.dll build/wv2fix/version.dll "
check "release: checksum file" test -s "$R/dist/revit-macos-shims-9.9.9.zip.sha256"

echo; echo "$((n - fails))/$n passed"
[ "$fails" = 0 ]
