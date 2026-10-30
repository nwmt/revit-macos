# Restore points of ./revit: an exact APFS clone of a bottle, kept beside the Bottles folder, that ./revit rollback brings
# back to the same name. Wine never runs in one, so its BottleID, links and menu records stay as they are. Sourced by
# ./revit after common.sh. <root>/<bottle>/<id>/{point.conf,bottle/}; <id> is YYYYMMDD-HHMMSS. In <root>/<bottle>/ also
# what a run cut short left: <id>.partial, restoring.<id>, replaced.<id>. A finished point appears and goes by one rename.
# REVIT_FREE_GB, REVIT_SWAP_FAIL_AT: tests only.
POINT_NEED_GB=25         # a new bottle (install.sh: space_for "$BOTTLES"): the point keeps the old one's space taken
POINT_NEED_ALL_GB=55     # with a download and an unpack on that volume too
POINT_WHY=""; POINT_NO_SPACE=0; POINT_ID=""

points_root() { # the folder of all points: beside the real Bottles folder (CrossOver lists whatever is in Bottles)
  local b; b="$(cd -P "$BOTTLES" 2>/dev/null && pwd)" || b="$BOTTLES"
  echo "$(dirname "$b")/Revit Restore Points"
}
points_dir() { echo "$(points_root)/$1"; }   # $1 = bottle
point_get() { sed -n "s/^$2=//p" "$1/point.conf" 2>/dev/null | head -1; }   # $1 = point folder, $2 = key
points_names() { # the bottles that have a folder here, one per line
  local d; for d in "$(points_root)"/*/; do d="${d%/}"; [ -d "$d" ] && [ ! -L "$d" ] && basename "$d"; done
  return 0
}
points_ids() { # $1 = bottle, $2 = year ("" = any): its finished points, newest first. point.conf must name them: a point
  # of another year is never brought back or deleted through this one
  local d id p="$(points_dir "$1")"
  [ ! -L "$p" ] || return 0
  for d in "$p"/*/; do
    d="${d%/}"; id="${d##*/}"
    [[ "$id" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [ ! -L "$d" ] && [ -d "$d/bottle" ] || continue
    [ "$(point_get "$d" bottle)" = "$1" ] || continue
    [ -z "$2" ] || [ "$(point_get "$d" year)" = "$2" ] || continue
    echo "$id"
  done | sort -r
}
points_leftovers() { # $1 = bottle: what a run cut short left, one path per line
  local f
  for f in "$(points_dir "$1")"/*.partial "$(points_dir "$1")"/restoring.* "$(points_dir "$1")"/replaced.*; do
    [ -e "$f" ] && echo "$f"
  done
  return 0
}
point_rm() { # $1 = a folder of ours: deleted; a read-only folder in it gets write access first. Links are not followed
  rm -rf "$1" 2>/dev/null; [ -e "$1" ] || return 0
  chmod -R u+w "$1" 2>/dev/null; rm -rf "$1" 2>/dev/null; [ ! -e "$1" ]
}
point_drop() { # $1 = bottle, $2 = id: first no longer a point, then deleted, so a delete cut short leaves no half a point
  local d; d="$(points_dir "$1")/$2"
  mv "$d" "$d.partial" 2>/dev/null && point_rm "$d.partial"
}
points_clean() { # $1 = bottle: what a run cut short left. Under the lock only
  local f ok=0
  while IFS= read -r f; do [ -z "$f" ] || point_rm "$f" || ok=1; done <<<"$(points_leftovers "$1")"
  return $ok
}
points_tidy() { rmdir "$(points_dir "$1")" 2>/dev/null; rmdir "$(points_root)" 2>/dev/null; return 0; }   # $1 = bottle
points_gb() { /usr/bin/awk -v b="${1:-0}" 'BEGIN { printf "%.0f", b / 1e9 }'; }   # $1 = bytes
point_why_not() { # $1 = bottle path, $2 = year: 0 when a point can be made now; else 1, with POINT_WHY and POINT_NO_SPACE
  local root have d need="$POINT_NEED_GB" free
  POINT_WHY=""; POINT_NO_SPACE=0; root="$(points_root)"
  bottles_on_apfs "$1" || { POINT_WHY="the bottles are not on an APFS volume, so a copy would take the full size of the bottle"; return 1; }
  have="$(stat -L -f %d "$1" 2>/dev/null)"
  [ "$(volume_id "$root")" = "$have" ] || { POINT_WHY="the folder for restore points is on another volume than the bottle"; return 1; }
  d="$root"; while [ ! -e "$d" ]; do d="$(dirname "$d")"; done
  [ -w "$d" ] || { POINT_WHY="cannot write to $(tilde "$d")"; return 1; }
  [ -d "$(revit_extracted "$2")" ] && [ "${REVIT_REEXTRACT:-0}" != 1 ] \
    || [ "$(volume_id "$DATA/installers/extracted")" != "$have" ] || need="$POINT_NEED_ALL_GB"   # the installers may be on another disk
  free="${REVIT_FREE_GB:-$(free_gb "$BOTTLES")}"
  [ "$free" -ge "$need" ] && return 0
  POINT_WHY="only $free GB free, and a rebuild that keeps the old bottle needs about $need GB"; POINT_NO_SPACE=1; return 1
}
point_take() { # $1 = bottle, $2 = year, $3 = bottle path: ends what runs in the bottle (the licensing services run for
  # hours) and clones it; sets POINT_ID. 1 with POINT_WHY; nothing of it stays. Under the lock only
  local dir id tmp b; dir="$(points_dir "$1")"; id="$(date +%Y%m%d-%H%M%S)"; tmp="$dir/$id.partial"
  [ ! -e "$dir/$id" ] || { POINT_WHY="a restore point of this second is there"; return 1; }
  mkdir -p "$tmp/bottle" || { POINT_WHY="cannot write to $(tilde "$dir")"; return 1; }
  WINEPREFIX="$3" "$CX/bin/wineserver" -k 2>/dev/null </dev/null 7>&- 9>&-
  if ! wait_stopped "$3" 30; then
    POINT_WHY="programs still run in $1: quit them with ./revit stop $2$(bottle_sfx "$1" "$2")"; point_rm "$tmp"; return 1
  fi
  if ! bottle_copy_at_rest "$3" "$tmp/bottle"; then
    case "$COPY_WHY" in
      busy) POINT_WHY="CrossOver is busy with $1; try again in a minute" ;;
      copy) POINT_WHY="copying the bottle failed" ;;
      *) POINT_WHY="programs started in $1 while it was copied" ;;
    esac
    point_rm "$tmp"; return 1
  fi
  b="$(du -sk "$tmp/bottle" 2>/dev/null | cut -f1)"; [[ "$b" =~ ^[0-9]+$ ]] && b=$((b * 1024)) || b=0
  printf 'year=%s\nbottle=%s\ntime=%s\nbytes=%s\nreason=rebuild\n' "$2" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$b" > "$tmp/point.conf" \
    && mv "$tmp" "$dir/$id" || { POINT_WHY="could not write the restore point"; point_rm "$tmp"; return 1; }
  POINT_ID="$id"
}
point_swap() { # $1 = bottle path, $2 = the folder with the clone, $3 = a new folder for what is in the bottle now. The
  # bottle's folder stays: CrossOver's lock goes by its inode, and a start that waits for the lock looks the bottle up
  # again by its path. No folder there: the clone takes its place. rename() and nothing else, deaf to signals; on a failure
  # everything goes back and it ends with 1, or with 2 when something could not go back: $3 then holds it
  /usr/bin/perl -e '$SIG{$_} = "IGNORE" for qw(INT TERM HUP);
    my ($b, $in, $out, $failat) = @ARGV; my ($n, @o, @i) = (0);
    sub names { opendir(my $d, $_[0]) or exit 1; my @l = grep { !/^\.\.?$/ } readdir $d; return @l }
    if (!lstat $b) { rename($in, $b) or exit 1; exit 0 }
    my @ob = names($b); my @ib = names($in);   # both read before anything moves
    mkdir $out or exit 1;
    sub undo { my $bad = 0; rename("$b/$_", "$in/$_") or $bad = 1 for reverse @i; rename("$out/$_", "$b/$_") or $bad = 1 for reverse @o; exit($bad ? 2 : 1) }
    for (@ob) { undo() if ++$n == $failat; rename("$b/$_", "$out/$_") or undo(); push @o, $_ }
    for (@ib) { undo() if ++$n == $failat; rename("$in/$_", "$b/$_") or undo(); push @i, $_ }
    exit 0' "$1" "$2" "$3" "${REVIT_SWAP_FAIL_AT:-0}"
}
