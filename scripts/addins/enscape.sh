# Enscape (Chaos): real-time rendering. The installer comes from your Chaos account (./revit addins import enscape <file>);
# installing it accepts the Enscape EULA.
ADDIN_NAME="Enscape"
ADDIN_ABOUT="Real-time rendering (installer from your Chaos account)"
ADDIN_TESTED=(2020 2027)
ADDIN_EULA="https://www.chaos.com/eula"
ADDIN_AFTER=(trust)
ADDIN_TOOL=""
ADDIN_STEP=enscape
addin_files() {
  case "$1" in
    2020) printf 'own\tenscape/Enscape-3.4.4-94564.msi\t-\t-\n'; printf 'own\t../redist/nuget/system.valuetuple.4.5.0.nupkg\t-\t-\n' ;;
    2027) printf 'own\tenscape/Enscape-4.18.2.1657-lts.exe\t-\t-\n' ;;
  esac
}
addin_is_installed() { [ -d "$B/drive_c/Program Files/Enscape" ]; }
