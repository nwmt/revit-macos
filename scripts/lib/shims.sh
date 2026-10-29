# Our shims: the list, the pinned prebuilt release, ensure_shim. Source with . "$ROOT/scripts/lib/shims.sh"
# After publishing a new release (git tag vX.Y.Z → .github/workflows/release.yml), bump both values below.
SHIMS_VERSION=0.11.0
SHIMS_SHA256=c33212087159bdfef16f7a699c6946e4b2f56c9708c5008b2b0ede58b9ee5500
SHIMS_REPO="${SHIMS_REPO:-nwmt/revit-macos}"
# every shim: its sources in tools/shims/<name>/, its file in build/<name>/ (how to build each: scripts/build-shims.sh).
# The steps, CI and the release take this list
SHIMS=(d3dwp dpapi hittest mcphost mcppipes ncryptshim pdfprinter rvtfix svcshim themeset tlbpin vkshim wbemshim wv2fix)
# what ends up in the files: if any differs from the pinned tag, the release no longer matches them. Not this file:
# its pin changes after every release
SHIMS_SOURCES=(tools/shims scripts/build-shims.sh)

ensure_shim() { # $1 = shim: build it from source, or take the prebuilt release file (scripts/build-shims.sh decides).
  # 0 when its file is in $(shim_dir)/<shim>/ afterwards. In the app (REVIT_BUNDLED=1) the release is all there is
  if [ "${REVIT_BUNDLED:-0}" = 1 ]; then   # each shim has a .dll or an .exe: either counts
    local f
    [ "$(cat "$(shim_dir)/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] || { echo "the shims in $(shim_dir) are not v$SHIMS_VERSION"; return 1; }
    for f in "$(shim_dir)/$1"/*.dll "$(shim_dir)/$1"/*.exe; do [ -f "$f" ] && return 0; done
    echo "no $1 in $(shim_dir)"; return 1
  fi
  "$ROOT/scripts/build-shims.sh" "$1" || return 1
}
release_complete() { # $1 = folder: a .dll or .exe in <folder>/<shim>/ for every shim of SHIMS (get-shims.sh, the app's build)
  local s f found
  for s in "${SHIMS[@]}"; do
    found=""; for f in "$1/$s"/*.dll "$1/$s"/*.exe; do [ -f "$f" ] && found=1; done
    [ -n "$found" ] || return 1
  done
}
