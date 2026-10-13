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
revit_installers() { echo "$ROOT/installers/revit$1"; }                    # downloads (gitignored)
revit_extracted()  { echo "$ROOT/installers/extracted/revit$1"; }          # unpacked (gitignored)
revit_dist() { # the installer root (setup.xml): the unpacked folder (2023+) or its one subfolder (multi-part 2020)
  local d; d="$(revit_extracted "$1")"
  [ -f "$d/setup.xml" ] || [ -f "$d/Setup.ini" ] || d="$(ls -d "$d"/*/ 2>/dev/null | head -1)"
  echo "${d%/}"
}

# Until stage 1 is done: the old scripts (install-odis.sh, d8-addins.sh, inspect-installer.sh, get-redist.sh,
# install.sh, revit) still ask for these. Removed in the commit that deletes their last caller.
revit_dotnet()    { load_profile "$1" && echo "$DOTNET"; }
revit_prodkey()   { load_profile "$1" && echo "$PRODKEY"; }
revit_pkgs_core() { load_profile "$1" && echo "$PKGS"; }
revit_dynamo()    { load_profile "$1" && [ -n "$DYNAMO" ] && echo "$DYNAMO"; }
revit_expect()    { echo "not tested"; }
REVIT_ADDIN_YEARS=(2020 2023 2024 2025 2026)
