# Our shim DLLs: the pinned prebuilt release and the "prebuilt or compile" rule. Source with . "$ROOT/scripts/lib/shims.sh"
# After publishing a new release (git tag vX.Y.Z → .github/workflows/release.yml), bump both values below.
SHIMS_VERSION=0.5.0
SHIMS_SHA256=46c83cc2e3702764693f38930532028e877aec6caf1b5015de6d75ec793ff807
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

# The shims the steps use, by name, and the file each build leaves in build/ (stage 3 moves them to tools/shims/).
shim_file() {
  case "$1" in
    d3dwp) echo d3dwp/d3dwp.dll ;;             ncrypt-shim) echo ncrypt-shim/ncrypt.dll ;;
    pdf-printer) echo pdf-printer/add_printer.exe ;; rvtfix) echo rvtfix/rvtfix.dll ;;
    svcshim) echo svcshim/svcshim.exe ;;       tlbpin) echo tlbpin/msls31.dll ;;
    vkshim) echo vkshim/vulkan-1.dll ;;        wbem-shim) echo wbem-shim/wbemshim.dll ;;
    wv2fix) echo wv2fix/version.dll ;;         *) return 1 ;;
  esac
}
ensure_shim() { # $1 = shim: build it from source, or take the prebuilt release DLL (cc_or_prebuilt in the build
  # script decides). 0 when its file is in build/ afterwards
  local f s="$1"
  f="$(shim_file "$1")" || { echo "unknown shim: $1"; return 1; }
  [ "$s" = pdf-printer ] && s=add-printer
  "$ROOT/scripts/build-$s.sh" || return 1
  [ -f "$ROOT/build/$f" ] || { echo "build/$f is missing after its build"; return 1; }
}
