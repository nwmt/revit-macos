#!/usr/bin/env bash
# The trackpad helper keeps its CDHash from release to release: macOS ties the helper's permission to it, so a new one
# makes every user grant the permission again. app/build.sh runs this after app/sign.sh: the helper's CDHash must be
# the one TRACKPAD_HELPER_CDHASH records. A new one fails the build until a person bumps TRACKPAD_HELPER_VERSION and
# records it (a changed helper, compiler or SDK all give one). TRACKPAD_HELPER_CDHASH_CHECK=0 skips it (local builds
# with another toolchain).
# Usage: app/check-helper-cdhash.sh <the .cdhash file app/sign.sh wrote> <app.conf>
set -euo pipefail
[ $# = 2 ] || { echo "Usage: app/check-helper-cdhash.sh <cdhash file> <app.conf>" >&2; exit 2; }
. "$2"
got="$(cat "$1" 2>/dev/null || true)"
[ "${TRACKPAD_HELPER_CDHASH_CHECK:-1}" != 0 ] || { echo ">> trackpad helper CDHash $got (not checked)" >&2; exit 0; }
[[ "$got" =~ ^[0-9a-f]{40}$ ]] || { echo "!! no CDHash of the trackpad helper in $1" >&2; exit 1; }
if [ "$got" != "${TRACKPAD_HELPER_CDHASH:-}" ]; then
  echo "!! the trackpad helper's CDHash is $got; TRACKPAD_HELPER_CDHASH in app/app.conf says '${TRACKPAD_HELPER_CDHASH:-}'." >&2
  echo "   If the helper changed: bump TRACKPAD_HELPER_VERSION ($TRACKPAD_HELPER_VERSION) and record $got (users grant the permission again)." >&2
  exit 1
fi
echo ">> trackpad helper CDHash $got: as recorded" >&2
