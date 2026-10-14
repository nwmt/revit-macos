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

echo; echo "$((n - fails))/$n passed"
[ "$fails" = 0 ]
