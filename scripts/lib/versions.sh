# Revit versions: which years this repo installs (one profile each in scripts/profiles/), bottle names, installer
# paths. Source with: . "$ROOT/scripts/lib/versions.sh" (scripts/lib/common.sh does it). Defines functions only.

in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

revit_bottle_name_ok() { # the name ends up in shell commands, AppleScript and app names: keep it plain.
  # "default" is CrossOver's alias for another bottle (CXBottle.pm), so a command could hit the wrong one
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$1" != default ]
}
revit_bottle_default() { echo "rvt$1-a"; }   # name of the version's first bottle

revit_years() { # the years with a profile, oldest first
  local f; for f in "$ROOT"/scripts/profiles/[0-9][0-9][0-9][0-9].sh; do [ -f "$f" ] && basename "$f" .sh; done; return 0
}
revit_supported() { [[ "$1" =~ ^[0-9]{4}$ ]] && [ -f "$ROOT/scripts/profiles/$1.sh" ]; }
REVIT_SUPPORTED=(); for _y in $(revit_years); do REVIT_SUPPORTED+=("$_y"); done; unset _y

load_profile() { # $1 = year: sets YEAR and the profile variables (scripts/profiles/<year>.sh); 1 = no such profile
  INSTALLER=""; DOTNET=""; PRODKEY=""; SIGNIN=""; LICENSING_OK=""; STEPS=(); PKGS=""; REVITINI=(); THEME=0
  RICHEDIT=(); RVTFIX_ENV=(); DYNAMO=""; ADDIN_STEPS=(); ADDIN_WPF_SW=0; LOOKUP=""; PYREVIT=""; PYREVIT_ATTACH=""; ENSCAPE=""
  revit_supported "$1" || return 1
  . "$ROOT/scripts/profiles/$1.sh"; YEAR="$1"
}

revit_dir_unix() { echo "$1/drive_c/Program Files/Autodesk/Revit $2"; }   # $1 = bottle path, $2 = year
revit_input()     { echo "$DATA/installers/revit$1"; }   # what the install reads: a folder, or a link to the user's
revit_downloads() { # where downloads go: the input folder, unless it is a link to the user's folder (never written)
  if [ -L "$DATA/installers/revit$1" ]; then echo "$DATA/installers/revit$1-dl"; else echo "$DATA/installers/revit$1"; fi
}
revit_extracted()  { echo "$DATA/installers/extracted/revit$1"; }          # unpacked (gitignored)
revit_dist_of() { # $1 = an unpacked folder → its installer root (setup.xml): the folder (2023+) or its one subfolder (2020)
  local d="$1"; [ -f "$d/setup.xml" ] || [ -f "$d/Setup.ini" ] || d="$(ls -d "$d"/*/ 2>/dev/null | head -1)"; echo "${d%/}"
}
revit_dist() { revit_dist_of "$(revit_extracted "$1")"; }
revit_main_installer() { # $1 = year, $2 = source.json (resolved here when not given): the file to unpack
  local sl="${2:-}" tmp=""
  if [ -z "$sl" ]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/revit-source.XXXXXX")"; sl="$tmp"
    python3 -I "$ROOT/tools/installer_source.py" resolve "$1" "$(revit_input "$1")" "$(revit_downloads "$1")" "$ROOT/installers/CHECKSUMS.txt" "$sl" >/dev/null 2>&1
  fi
  /usr/bin/perl -MJSON::PP -0 -ne 'my $s = eval { decode_json($_) } or exit 0; print "$_->{path}\n" for grep { $_->{extract} } @{$s->{files}}' "$sl"
  [ -z "$tmp" ] || rm -f "$tmp"
}
