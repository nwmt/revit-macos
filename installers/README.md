# installers/

Put the files that `./revit install` needs here. Revit comes only from your own Autodesk Account
(manage.autodesk.com → Products and Services → Revit; older versions under **Previous versions**). This project does
not provide or link to any Autodesk files.

## Revit installer

| Revit | What to download | Put it in |
|---|---|---|
| 2020 | All 7 parts `Revit_2020_G1_Win_64bit_r3_dlm_00N_007.sfx.exe` (about 12.2 GB) | `installers/revit2020/` |
| 2023 | All 5 parts `Revit_2023_G1_Win_64bit_dlm_00N_005.sfx.exe` (about 8.3 GB) | `installers/revit2023/` |
| 2024–2027 | `Create_Installer_RVT_<year>_…_WIN64.exe` (32 MB) | `installers/revit<year>/` |

For 2024 and newer the small Create Installer file is enough. `./revit install` reads from it where Autodesk keeps
Revit, downloads the base release (10–11 GB) and the latest update (1.5–3.7 GB, checksum-checked), and installs
Revit already updated. An interrupted download resumes on the next run. If you already have the base files from an
older download (the parts, or the two `RVT_<year>_NA_win_db_…` files), they are used as they are.

Keep the file names as Autodesk gives them. Only the versions you install need to be here.

## Extra files

- **msls31.dll** (all versions, required) → `installers/redist/win7sp1/x64/`.
  Copy `C:\Windows\System32\msls31.dll` from any 64-bit Windows 7 or 10 PC. Revit needs it to show text.
- **.NET Framework 4.0** (Revit 2020, 2023, 2024) → `installers/redist/`.
  The offline installer `dotNetFx40_Full_x86_x64.exe` from Microsoft.
- **WebView2 runtime** (Revit 2024 and newer, recommended) → `installers/redist/webview2/`.
  The Evergreen Standalone x64 installer from Microsoft (go.microsoft.com/fwlink/?linkid=2124701). Without it the
  start screen and Manage Links stay white.
- **RichEdit files**: `./revit install` downloads them from Microsoft by itself (Windows 7 SP1 package, about
  947 MB, once).

## Add-ins (optional)

For `./revit addins`. RevitLookup comes from github.com/lookup-foundation/RevitLookup, pyRevit from
github.com/pyrevitlabs/pyRevit.

| Add-in | Revit | File | Put it in |
|---|---|---|---|
| RevitLookup | 2020 | `RevitLookup-2020.0.0.3-SingleUser.msi` | `installers/addins/revitlookup/` |
| RevitLookup | 2023 | `RevitLookup-2023.5.4-SingleUser.msi` | `installers/addins/revitlookup/` |
| RevitLookup | 2024 | `RevitLookup-2024.3.4-SingleUser.msi` | `installers/addins/revitlookup/` |
| RevitLookup | 2025 | `RevitLookup-2025.2.4-SingleUser.msi` | `installers/addins/revitlookup/` |
| RevitLookup | 2026 | `RevitLookup-2026.1.4-SingleUser.msi` | `installers/addins/revitlookup/` |
| pyRevit 4.8.12 | 2020 | `pyRevit_4.8.12.22247_signed.exe` | `installers/addins/pyrevit48/` |
| pyRevit 7.0.0 | 2023–2026 | `pyRevit_7.0.0.26278_signed.exe` | `installers/addins/pyrevit7/` |

## Disk space

Approximate sizes:

| Revit | Download | Unpacked | Bottle |
|---|---:|---:|---:|
| 2020 | 12 GB | 17 GB | 20–30 GB |
| 2023 | 8.3 GB | 12.5 GB | 12 GB |
| 2024 | 11 GB | 13 GB | 16 GB |
| 2025 | 15 GB | 12 GB | 7 GB |
| 2026 | 13 GB | 11 GB | 7 GB |
| 2027 | 12 GB | 11 GB | not measured |

After the install you can delete `installers/extracted/revit<year>` (the unpacked files). `./revit rebuild` then
unpacks them again from the download; `./revit remove` deletes them for you.

## Checksums

[CHECKSUMS.txt](CHECKSUMS.txt) lists the files we tested. To compare yours:

```bash
cd installers && shasum -a 256 revit<year>/*
```

A different checksum for a Revit file means a different build from the one we tested. It may still work.

<details>
<summary>Full folder layout</summary>

```
installers/
├── revit2020/
│   ├── Revit_2020_G1_Win_64bit_r3_dlm_001_007.sfx.exe     all 7 parts (6 × 1.97 GB + 429.8 MB)
│   ├── …
│   └── Revit_2020_G1_Win_64bit_r3_dlm_007_007.sfx.exe
├── revit2023/
│   ├── Revit_2023_G1_Win_64bit_dlm_001_005.sfx.exe        all 5 parts (4 × 1.97 GB + 418 MB)
│   ├── …
│   └── Revit_2023_G1_Win_64bit_dlm_005_005.sfx.exe
├── revit2024/
│   ├── Create_Installer_RVT_2024_3_6_English_WIN64.exe    the only file you need
│   ├── Revit_2024_G1_Win_64bit_r2_dlm_001_005.sfx.exe     downloaded: 5 parts
│   ├── …
│   └── update/Revit_2024_3_6.exe                          downloaded
├── revit2025/
│   ├── Create_Installer_RVT_2025_5_English_WIN64.exe      the only file you need
│   ├── RVT_2025_NA_win_db_001_002.exe                     downloaded
│   ├── RVT_2025_NA_win_db_002_002.7z                      downloaded
│   └── update/Revit_2025_5_0.exe                          downloaded
├── revit2026/
│   ├── Create_Installer_RVT_2026_5_English_WIN64.exe      the only file you need
│   ├── RVT_2026_NA_win_db_001_002.exe                     downloaded (or the old two-file download)
│   ├── RVT_2026_NA_win_db_002_002.7z
│   └── update/Revit_2026_5_0.exe                          downloaded
├── revit2027/
│   ├── Create_Installer_RVT_2027_3_English_WIN64.exe      the only file you need
│   ├── RVT_2027_NA_win_db_001_002.exe                     downloaded (or the old two-file download)
│   ├── RVT_2027_NA_win_db_002_002.7z
│   └── update/Revit_2027_3_0.exe                          downloaded
├── redist/
│   ├── win7sp1/x64/msls31.dll                             all versions
│   ├── dotNetFx40_Full_x86_x64.exe                        2020, 2023, 2024
│   └── webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe   2024 and newer, recommended
├── addins/                                                optional
│   ├── revitlookup/RevitLookup-<year>….msi
│   ├── pyrevit48/pyRevit_4.8.12.22247_signed.exe          2020
│   └── pyrevit7/pyRevit_7.0.0.26278_signed.exe            2023–2026
└── extracted/                                             created by ./revit install; safe to delete afterwards
```

</details>
