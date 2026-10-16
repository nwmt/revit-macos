#!/usr/bin/env bash
# Signs <App>.app ad hoc (no Developer ID yet), inside-out: every Mach-O image first, deepest path first, then the
# bundle, which seals everything else (scripts, Python's .py files, static archives) as resources. Refuses an image
# built for a newer macOS than the app's minimum. No hardened runtime: with ad hoc signatures (no Team ID) library
# validation would refuse Python's own extensions.
# Usage: app/sign.sh <app> <minimum macOS> [inventory file]   (the inventory: "<path in the app><TAB><archs>" per image)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/app/app.conf"
[ $# -ge 2 ] || { echo "Usage: app/sign.sh <app> <minimum macOS> [inventory file]" >&2; exit 2; }
APP="${1%/}"; MIN="$2"; INV="${3:-}"
die() { echo "!! $*" >&2; exit 1; }
[ -d "$APP/Contents" ] || die "not an app: $APP"
ver_le() { /usr/bin/perl -e 'my @a = split /\./, $ARGV[0]; my @b = split /\./, $ARGV[1];
  for my $i (0 .. 2) { my ($x, $y) = ($a[$i] // 0, $b[$i] // 0); exit 0 if $x < $y; exit 1 if $x > $y } exit 0' "$1" "$2"; }
is_image() { # a loadable Mach-O (thin or universal; a universal file's first line names its first slice). Not one:
  # static archives ("current ar archive") and object files, which stay resources
  local d; d="$(file -b "$1" | head -1)"
  case "$d" in Mach-O*) case "$d" in *executable*|*"dynamically linked shared library"*|*bundle*) return 0 ;; esac ;; esac
  return 1
}
minos() { # $1 = file, $2 = arch → its minimum macOS
  local m; m="$(vtool -arch "$2" -show-build "$1" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
  [ -n "$m" ] || m="$(otool -arch "$2" -l "$1" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/ { f = 1 } f && $1 == "version" { print $2; exit }')"
  echo "$m"
}

images=(); while IFS= read -r f; do is_image "$f" && images+=("$f"); done < <(find "$APP/Contents" -type f)
[ ${#images[@]} -gt 0 ] || die "no Mach-O image in $APP"
[ -z "$INV" ] || : > "$INV"
sorted=(); while IFS= read -r f; do sorted+=("$f"); done < <(for f in "${images[@]}"; do
  printf '%s\t%s\n' "$(tr -cd / <<<"$f" | wc -c | tr -d ' ')" "$f"; done | sort -rn -k1,1 | cut -f2-)
for f in "${sorted[@]}"; do
  archs="$(lipo -archs "$f")"
  for a in $archs; do
    m="$(minos "$f" "$a")"; [ -n "$m" ] || die "${f#"$APP/"} ($a): no minimum macOS in the file"
    ver_le "$m" "$MIN" || die "${f#"$APP/"} ($a) needs macOS $m, newer than the app's minimum $MIN (app/app.conf)"
  done
  [ -z "$INV" ] || printf '%s\t%s\n' "${f#"$APP/"}" "$archs" >> "$INV"
done
for f in "${sorted[@]}"; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null || die "cannot sign ${f#"$APP/"}"; done
codesign --force --sign - --timestamp=none --identifier "$APP_BUNDLE_ID" "$APP" || die "cannot sign $APP"
codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | grep -v '^\(.*: valid on disk\|.*: satisfies its Designated Requirement\)$' >&2 || true
codesign --verify --strict --deep "$APP" || die "$APP does not verify"
for f in "${sorted[@]}"; do codesign --verify --strict "$f" || die "${f#"$APP/"} does not verify"; done
echo ">> signed ad hoc: $APP (${#sorted[@]} Mach-O images)"
