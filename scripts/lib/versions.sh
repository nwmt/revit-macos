# Revit version metadata — single source for the scripts. Source with: . "$ROOT/scripts/lib/versions.sh"
# Fields: year | .NET (what Revit needs) | .NET kind | expectation based on our data
# Requirement sources: Autodesk "System requirements for Revit 20XX" pages, Autodesk blog (2025/2026 → .NET 8).
# 2027 → .NET 10: the installer ships windowsdesktop-runtime-10.0.0 (pkg.dotnet100.xml).
REVIT_YEARS=(2020 2021 2022 2023 2024 2025 2026 2027)

revit_dotnet() { # .NET that Revit is built on
  case "$1" in
    2020) echo "netfx47";;   # stock 4.7 from the installer; 4.7.2/4.8 crash Revit 2020 under Wine
    2021|2022|2023|2024) echo "netfx48";;
    2025|2026) echo "net8";;
    2027) echo "net10";;
    *) return 1;;
  esac
}

revit_expect() { # expectation before trying (not a fact!)
  case "$1" in
    2020) echo "works";;
    2021|2022|2023|2024) echo "unlikely: CLR 4.8 crashes with Revit 2020";;
    2025|2026) echo "candidate: CoreCLR 8 works under Wine";;
    2027) echo "candidate: like 2026, but .NET 10 (untested under Wine)";;
  esac
}

revit_dir_unix() { echo "$1/drive_c/Program Files/Autodesk/Revit $2"; }   # $1 = bottle path, $2 = year
revit_exe_win()  { echo "C:\\Program Files\\Autodesk\\Revit $1\\Revit.exe"; }
revit_installers() { echo "$ROOT/installers/revit$1"; }                      # installer (gitignored)
revit_extracted()  { echo "$ROOT/installers/extracted/revit$1"; }            # extracted (gitignored)
revit_bottle_default() { echo "rvt$1-a"; }                                    # name of the version's first bottle
revit_prodkey() { # ADLM_PRODKEY from the RVT.msi Property table
  case "$1" in 2020) echo 829L1;; 2026) echo 829R1;; 2027) echo 829S1;; *) return 1;; esac
}
revit_pkgs_core() { # core ODIS packages for install-odis.sh pkgs (names from manifest/app.RVT.xml): no Dynamo, Twinmotion, other languages
  case "$1" in
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
