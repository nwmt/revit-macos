# RevitLookup (github.com/lookup-foundation/RevitLookup): look into the Revit database of a model.
ADDIN_NAME="RevitLookup"
ADDIN_ABOUT="Look into the Revit database of a model"
ADDIN_TESTED=(2020 2023 2024 2025 2026)
ADDIN_EULA=""
ADDIN_AFTER=(trust wpfsw)
ADDIN_TOOL=""
ADDIN_STEP=revitlookup
addin_files() { # $1 = year: <auto|own> <file under installers/addins/> <url> <sha256>; the files the profiles' LOOKUP name
  local g=https://github.com/lookup-foundation/RevitLookup/releases/download
  case "$1" in
    2020) printf 'auto\trevitlookup/RevitLookup-2020.0.0.3-SingleUser.msi\t%s\t%s\n' "$g/2023.1.0-EOL/RevitLookup-2020.0.0.3-SingleUser.msi" a5e760f77cf581d6a26f9d12c5b408dbded5c0a6dc4c955316e7de29e62843d3 ;;
    2023) printf 'auto\trevitlookup/RevitLookup-2023.5.4-SingleUser.msi\t%s\t%s\n' "$g/2027.0.4/RevitLookup-2023.5.4-SingleUser.msi" 20190d68e6668e67aed225b80e4e762ff523d76589270bd5305e7bcbef58e9a3 ;;
    2024) printf 'auto\trevitlookup/RevitLookup-2024.3.4-SingleUser.msi\t%s\t%s\n' "$g/2027.0.4/RevitLookup-2024.3.4-SingleUser.msi" 7b9f08e68f902d0cab977618ddf0adc9bd02bbb11c4ec3414eed3971a272c1f0 ;;
    2025) printf 'auto\trevitlookup/RevitLookup-2025.2.4-SingleUser.msi\t%s\t%s\n' "$g/2027.0.4/RevitLookup-2025.2.4-SingleUser.msi" 06e9e6605a2df1104d67cde3e1c24d4b823b119e89f4a250915f0969b0a015cd ;;
    2026) printf 'auto\trevitlookup/RevitLookup-2026.1.4-SingleUser.msi\t%s\t%s\n' "$g/2027.0.4/RevitLookup-2026.1.4-SingleUser.msi" 81c61845d01f3990edaa7f7a6ea796a27c37cb7c5e8ca85032afb2969cf8a996 ;;
  esac
}
addin_is_installed() { local d; while IFS= read -r d; do ls "$d"/RevitLookup*.addin >/dev/null 2>&1 && return 0; done < <(addin_dirs); return 1; }
