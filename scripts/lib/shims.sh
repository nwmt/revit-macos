# Our shims: the list, the pinned prebuilt release, ensure_shim. Source with . "$ROOT/scripts/lib/shims.sh"
# After publishing a new release (git tag vX.Y.Z → .github/workflows/release.yml), bump both values below.
SHIMS_VERSION=0.6.0
SHIMS_SHA256=3968d0c15c8ef30bc3ecde672e4aca0a552bcab9be4f09694f79ac40306a7e69
SHIMS_REPO="${SHIMS_REPO:-nwmt/revit-macos}"
# every shim: its sources in tools/shims/<name>/, its file in build/<name>/ (how to build each: scripts/build-shims.sh).
# The steps, CI and the release take this list
SHIMS=(d3dwp ncryptshim pdfprinter rvtfix svcshim tlbpin vkshim wbemshim wv2fix)
# what ends up in the files: if any differs from the pinned tag, the release no longer matches them. Not this file:
# its pin changes after every release
SHIMS_SOURCES=(tools/shims scripts/build-shims.sh)

ensure_shim() { # $1 = shim: build it from source, or take the prebuilt release file (scripts/build-shims.sh decides).
  # 0 when its file is in build/<shim>/ afterwards
  "$ROOT/scripts/build-shims.sh" "$1" || return 1
}
