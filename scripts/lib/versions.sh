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
  RICHEDIT=(); RVTFIX_ENV=(); DYNAMO=""; ADDIN_STEPS=(); LOOKUP=""; PYREVIT=""; PYREVIT_ATTACH=""; ENSCAPE=""
  revit_supported "$1" || return 1
  . "$ROOT/scripts/profiles/$1.sh"; YEAR="$1"
}

revit_dir_unix() { echo "$1/drive_c/Program Files/Autodesk/Revit $2"; }   # $1 = bottle path, $2 = year
revit_installers() { echo "$DATA/installers/revit$1"; }                    # downloads (gitignored); may be a link: find -H
revit_extracted()  { echo "$DATA/installers/extracted/revit$1"; }          # unpacked (gitignored)
revit_dist() { # the installer root (setup.xml): the unpacked folder (2023+) or its one subfolder (multi-part 2020)
  local d; d="$(revit_extracted "$1")"
  [ -f "$d/setup.xml" ] || [ -f "$d/Setup.ini" ] || d="$(ls -d "$d"/*/ 2>/dev/null | head -1)"
  echo "${d%/}"
}
revit_main_installer() { # $1 = year: the installer's main file in installers/revit<year>/, not an update in update/:
  # part 001 of a multi-part download (2020, the 2024 base), else the largest archive (in 2023+ downloads
  # *_001_002.exe is a 16 MB bootstrapper and the payload is *_002_002.7z)
  local src first; src="$(revit_installers "$1")"
  first="$(find -H "$src" -maxdepth 2 -path "$src/update" -prune -o -type f -iname '*_001_0*.sfx.exe' -print 2>/dev/null | sort | head -1)"
  if [ -n "$first" ]; then echo "$first"; return 0; fi
  find -H "$src" -maxdepth 2 -path "$src/update" -prune -o -type f \( -iname '*.exe' -o -iname '*.iso' -o -iname '*.zip' -o -iname '*.7z' \) \
    -exec stat -f '%z %N' {} + 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-
}
