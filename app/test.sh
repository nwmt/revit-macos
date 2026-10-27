#!/bin/bash
# Runs the app's Swift tests (AppCoreTests): app/test.sh [swift test arguments…], e.g. app/test.sh --filter Event.
# No CrossOver, no Revit, no network: the tests run the engine of this repo in a sandbox. One test at a time
# (--no-parallel): tests that start processes must not overlap.
# With only the Command Line Tools (no Xcode): swift-testing's macros need the CLT's plugin folder, and the CLT's macOS 27
# SDK lacks SwiftUI's macro plugin (an Xcode part), so the macOS 26 SDK is used when there: it builds for the minimum
# macOS 27 as well (the deployment target comes from Package.swift, not from the SDK).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
args=()
dev="$(xcode-select -p 2>/dev/null || true)"
case "$dev" in
  */CommandLineTools)
    [ -d "$dev/usr/lib/swift/host/plugins/testing" ] && args+=(-Xswiftc -plugin-path -Xswiftc "$dev/usr/lib/swift/host/plugins/testing")
    sdk="$dev/SDKs/MacOSX26.sdk"
    [ -n "${SDKROOT:-}" ] || [ ! -d "$sdk" ] || export SDKROOT="$sdk" ;;
esac
# SpawnProbe: the test "the run survives its launcher" starts a run through it, then it exits
swift build --package-path "$ROOT/app" --product SpawnProbe ${args[@]+"${args[@]}"} >&2
SPAWN_PROBE="$(swift build --package-path "$ROOT/app" --product SpawnProbe ${args[@]+"${args[@]}"} --show-bin-path)/SpawnProbe"
export SPAWN_PROBE
exec env LANG=en_US.UTF-8 swift test --package-path "$ROOT/app" --no-parallel ${args[@]+"${args[@]}"} "$@"
