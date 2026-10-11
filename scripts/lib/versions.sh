# Revit version metadata — single source for the scripts. Source with: . "$ROOT/scripts/lib/versions.sh"
# Fields: year | .NET (what Revit needs) | .NET kind | expectation based on our data
# Requirement sources: Autodesk "System requirements for Revit 20XX" pages, Autodesk blog (2025/2026 → .NET 8).
# 2027 → .NET 10: the installer ships windowsdesktop-runtime-10.0.0 (pkg.dotnet100.xml).
REVIT_YEARS=(2020 2021 2022 2023 2024 2025 2026 2027)
REVIT_SUPPORTED=(2020 2023 2024 2025 2026 2027)   # install.sh and ./revit accept these
REVIT_ADDIN_YEARS=(2020 2023 2024 2025 2026)      # scripts/d8-addins.sh knows their add-ins

in_list() { local x="$1" y; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

revit_bottle_name_ok() { # the name ends up in shell commands, AppleScript and app names: keep it plain.
  # "default" is CrossOver's alias for another bottle (CXBottle.pm), so a command could hit the wrong one
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$1" != default ]
}

revit_dotnet() { # .NET that Revit is built on
  case "$1" in
    2020) echo "netfx47";;   # stock 4.7 from the installer; 4.7.2/4.8 crash Revit 2020 under Wine
    2021|2022|2023|2024) echo "netfx48";;
    2025) echo "net8";;      # 2025.0; the 2025.5 update moves Revit to .NET 10, like 2026.5 (both get installed)
    2026) echo "net8";;      # 2026.0; the 2026.5 update moves Revit to .NET 10 and ships the runtime (both get installed)
    2027) echo "net10";;
    *) return 1;;
  esac
}

revit_expect() { # expectation before trying (not a fact!)
  case "$1" in
    2020) echo "works";;
    2023) echo "works";;
    2021|2022) echo "candidate: .NET Framework 4.8 works with Revit 2023";;
    2024) echo "candidate: .NET Framework 4.8 like 2023, sign-in and RealDWG like 2025";;
    2025|2026) echo "candidate: CoreCLR 8 works under Wine";;
    2027) echo "candidate: like 2026, but .NET 10 (untested under Wine)";;
  esac
}

revit_dir_unix() { echo "$1/drive_c/Program Files/Autodesk/Revit $2"; }   # $1 = bottle path, $2 = year
revit_exe_win()  { echo "C:\\Program Files\\Autodesk\\Revit $1\\Revit.exe"; }
revit_installers() { echo "$ROOT/installers/revit$1"; }                      # installer (gitignored)
revit_extracted()  { echo "$ROOT/installers/extracted/revit$1"; }            # extracted (gitignored)
revit_dist() { # the installer root (setup.xml): the extracted folder (2026+) or its one subfolder (multi-part downloads: 2020, 2023)
  local d; d="$(revit_extracted "$1")"
  [ -f "$d/setup.xml" ] || [ -f "$d/Setup.ini" ] || d="$(ls -d "$d"/*/ 2>/dev/null | head -1)"
  echo "${d%/}"
}
revit_bottle_default() { echo "rvt$1-a"; }                                    # name of the version's first bottle
revit_dynamo() { # Dynamo for Revit version: its settings folder %APPDATA%\Dynamo\Dynamo Revit\<version>
  case "$1" in 2020) echo 2.3;; 2023) echo 2.13;; 2024) echo 2.19;; 2025) echo 3.3;; *) return 1;; esac
}
revit_prodkey() { # ADLM_PRODKEY from the RVT.msi Property table
  case "$1" in 2020) echo 829L1;; 2023) echo 829O1;; 2024) echo 829P1;; 2025) echo 829Q1;; 2026) echo 829R1;; 2027) echo 829S1;; *) return 1;; esac
}
revit_pkgs_core() { # core ODIS packages for install-odis.sh pkgs (names from manifest/app.RVT.xml): no Dynamo, Twinmotion, other languages
  case "$1" in
    # 2023: Revit itself is in RVT.msi (no ADIX packages); materials CM2023/…2023
    2023) echo "RCLC|RCLCRVT|RVTCPSTLCON|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM2023|CMILB2023|PrismBaseImageLibrary2023|PrismLowImageLibrary2023|PrismMediumImageLibrary2023|UNITSCHEMAS|RCLEENU|RET|GenerativeDesign";;
    # 2024: Revit in RVT.msi as in 2023 (+ the update's RVTSP*.msp), sign-in, HIVE and RealDWG as in 2025; the rest of Revit
    # (CefSharp, ATF, shared and cloud parts with Dynamo) in the MSM_* ADIX packages
    2024) echo "RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|MSM_CEFSHARP|MSM_ATF|MSM_EXT|MSM_CLOUD|RET|GenerativeDesign";;
    # 2025: like 2026 without OpenUSD; adds RSA Interop and CEFSHARP (CefSharp, as in 2023); no ASC package; Dynamo 3.3 (ADIX)
    2025) echo "RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|ATF|CORE|CLOUD|SHARED|RVTONLY|CEFSHARP|RET|GenerativeDesign|DYNAMO_CORE|DYNAMO_DOCS";;
    2026) echo "RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|ATF|CORE|CLOUD|SHARED|RVTONLY|RET|OpenUSD|GenerativeDesign";;
    # 2027: materials v5, ENU content split into Imperial/Metric, core is CORE+COREADD+COREEXT; no RET, RSA RoReinf, Generative Design
    2027) echo "RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|CM5|CMILB5|PrismBaseImageLibrary5|PrismLowImageLibrary5|PrismMediumImageLibrary5|UNITSCHEMAS|UNITSCHEMASLOCALE|RCLEENUI|RCLEENUM|ATF|CORE|COREADD|COREEXT|CLOUD|SHARED|SHAREDRENDER|RVTONLY|RVTONLY_CLOUD|OpenUSD|Addins Manager";;
    *) return 1;;
  esac
}

# RFO Benchmark: archives installers/benchmark/RFOBenchmark_v<version>_<year>.{7z,zip} (gitignored), extracted to
# installers/benchmark/extracted/. Everything else (journals, Revit_<year>.ini, Revit paths) comes from Resources/ and XML —
# a new version = extract the archive, no script changes needed.
rfo_archive()   { { ls "$ROOT"/installers/benchmark/RFOBenchmark_v*_"$1".7z "$ROOT"/installers/benchmark/RFOBenchmark_v*_"$1".zip 2>/dev/null || :; } | head -1; }
rfo_resources() { # the benchmark's Resources folder for a year (nested in 2026: …/RFOBenchmark_v3.4_2026 - Proposed/Resources)
  local x; x=$(find "$ROOT/installers/benchmark/extracted" -path "*/Resources/RFOBenchmark_$1.xml" 2>/dev/null | sort | head -1)
  [ -n "$x" ] && dirname "$x"
}
