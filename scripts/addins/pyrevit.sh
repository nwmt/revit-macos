# pyRevit (github.com/pyrevitlabs/pyRevit): a Python scripting environment and toolbar for Revit.
# Fields read by scripts/lib/addins.sh; ADDIN_STEP is the run-steps step that installs it.
ADDIN_NAME="pyRevit"
ADDIN_ABOUT="Python scripting and a toolbar of tools"
ADDIN_TESTED=(2020 2023 2024 2025 2026)
ADDIN_EULA=""
ADDIN_AFTER=(trust wpfsw)
ADDIN_TOOL=""
ADDIN_STEP=pyrevit
addin_files() { # $1 = year: <auto|own> <file under installers/addins/> <url> <sha256>
  case "$1" in
    2020) printf 'auto\tpyrevit48/pyRevit_4.8.12.22247_signed.exe\t%s\t%s\n' \
            https://github.com/pyrevitlabs/pyRevit/releases/download/v4.8.12.22247%2B0031/pyRevit_4.8.12.22247_signed.exe \
            84d6f271638445f8c949aaf6f07ff902e3d44242441ee427cb34573531daba3a ;;
    2023|2024|2025|2026) printf 'auto\tpyrevit7/pyRevit_7.0.0.26278_signed.exe\t%s\t%s\n' \
            https://github.com/pyrevitlabs/pyRevit/releases/download/v7.0.0.26278%2B2233/pyRevit_7.0.0.26278_signed.exe \
            bf242d23f3ca8ae214f430aa29764f63e02756e7fcb620b21ca85965c8ee4476 ;;
  esac
}
addin_is_installed() { [ -d "$B/drive_c/users/crossover/AppData/Roaming/pyRevit-Master" ]; }
