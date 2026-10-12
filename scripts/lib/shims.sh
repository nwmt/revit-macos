# Our shim DLLs: the pinned prebuilt release and the "prebuilt or compile" rule. Source with . "$ROOT/scripts/lib/shims.sh"
# After publishing a new release (git tag vX.Y.Z → .github/workflows/release.yml), bump both values below.
SHIMS_VERSION=0.1.1
SHIMS_SHA256=9dcdc322c9771c9399813c4236c9883df4c26f39e609bd9b8cd00bd01283a98c
SHIMS_REPO="${SHIMS_REPO:-nwmt/revit-macos}"
# sources that end up in the DLLs: if any differ from the pinned tag, the release no longer matches them
SHIMS_SOURCES=(tools/d3d11-warp-shim tools/ncrypt-shim tools/pdf-printer tools/rvtfix tools/svcshim tools/tlbpin tools/vkshim tools/wbem-shim tools/wv2fix)

# For build-*.sh: $1 = the file it builds. Without the compiler, use the release DLL that get-shims.sh
# unpacked; otherwise fetch the compiler and build. A developer with the toolchain always builds from source.
cc_or_prebuilt() {
  [ -x "$CC" ] && return 0
  if [ -f "$ROOT/build/.prebuilt" ] && [ -f "$1" ]; then echo "prebuilt v$(cat "$ROOT/build/.prebuilt"): ${1#"$ROOT"/}"; exit 0; fi
  "$ROOT/scripts/get-toolchain.sh"
}
