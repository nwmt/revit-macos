# installers/

Put the files the install needs here.

**Revit installers come only from your own Autodesk Account** (manage.autodesk.com → Products and Services → Revit).
For older versions use **Previous versions**. This project does not provide or link to any Autodesk files.

**Revit 2024 and newer: Create Installer.** Autodesk Account now offers a 32 MB `Create_Installer_RVT_<year>_…_WIN64.exe`
(for example `Create_Installer_RVT_2027_3_English_WIN64.exe`). Put only that file into `installers/revit<year>/`.
`install.sh` reads from it where Autodesk keeps the files and downloads:

- the full installer of the base release (2024.1.1, 2025.0, 2026.0, 2027.0; 10–11 GB) into `installers/revit<year>/`;
- the update named in the file (2024.3.6, 2025.5, 2026.5, 2027.3; 1.5–3.7 GB) into `installers/revit<year>/update/`, checked against
  the SHA-256 Autodesk lists for it.

The update is laid over the base before installing, so Revit is installed already updated. An interrupted download
resumes on the next run. By hand: `scripts/get-revit.sh <year>`. If you already have the two base files (below),
they are used as they are.

## What goes where

```
installers/
├── revit2020/
│   ├── Revit_2020_G1_Win_64bit_r3_dlm_001_007.sfx.exe   Revit 2020 download: all 7 parts
│   ├── …                                                  (6 × 1.97 GB + 429.8 MB)
│   └── Revit_2020_G1_Win_64bit_r3_dlm_007_007.sfx.exe
├── revit2023/
│   ├── Revit_2023_G1_Win_64bit_dlm_001_005.sfx.exe      Revit 2023 download: all 5 parts
│   ├── …                                                  (4 × 1.97 GB + 418 MB)
│   └── Revit_2023_G1_Win_64bit_dlm_005_005.sfx.exe
├── revit2024/
│   ├── Create_Installer_RVT_2024_3_6_English_WIN64.exe the only file you need (Autodesk Account)
│   ├── Revit_2024_G1_Win_64bit_r2_dlm_001_005.sfx.exe downloaded by the install: 5 parts
│   ├── …
│   └── update/Revit_2024_3_6.exe                 downloaded by the install
├── revit2025/
│   ├── Create_Installer_RVT_2025_5_English_WIN64.exe   the only file you need (Autodesk Account)
│   ├── RVT_2025_NA_win_db_001_002.exe            downloaded by the install
│   ├── RVT_2025_NA_win_db_002_002.7z
│   └── update/Revit_2025_5_0.exe                 downloaded by the install
├── revit2026/
│   ├── Create_Installer_RVT_2026_5_English_WIN64.exe   the only file you need (Autodesk Account)
│   ├── RVT_2026_NA_win_db_001_002.exe            downloaded by the install (or the old two-file download)
│   ├── RVT_2026_NA_win_db_002_002.7z
│   └── update/Revit_2026_5_0.exe                 downloaded by the install
├── revit2027/
│   ├── Create_Installer_RVT_2027_3_English_WIN64.exe   the only file you need (Autodesk Account)
│   ├── RVT_2027_NA_win_db_001_002.exe            downloaded by the install (or the old two-file download)
│   ├── RVT_2027_NA_win_db_002_002.7z
│   └── update/Revit_2027_3_0.exe                 downloaded by the install
├── redist/
│   ├── win7sp1/x64/msls31.dll                    required for all versions (see below)
│   ├── dotNetFx40_Full_x86_x64.exe               Revit 2020, 2023 and 2024: Microsoft .NET Framework 4.0
│   └── webview2/MicrosoftEdgeWebView2RuntimeInstallerX64.exe   Revit 2024+, recommended
├── addins/                                       optional add-ins
│   ├── revitlookup/   RevitLookup-2020.0.0.3-SingleUser.msi, RevitLookup-2023.5.4-SingleUser.msi, RevitLookup-2025.2.4-SingleUser.msi, RevitLookup-2026.1.4-SingleUser.msi
│   ├── pyrevit48/     pyRevit_4.8.12.22247_signed.exe   (Revit 2020)
│   └── pyrevit7/      pyRevit_7.0.0.26278_signed.exe    (Revit 2023, 2025, 2026)
└── extracted/                                    created by the install; safe to delete afterwards
```

Use the file names as Autodesk gives them. Only the versions you install need to be present.

## The extra files

- **msls31.dll** (64-bit). Copy `C:\Windows\System32\msls31.dll` from any 64-bit Windows 7 or Windows 10 machine.
  Revit needs it to show text. Microsoft's Windows 7 SP1 package has no 64-bit copy, so it must come from a Windows machine.
- **RichEdit DLLs** (riched20, usp10 and others). The install downloads them from Microsoft automatically
  (Windows 7 SP1 package, about 947 MB, once) into `redist/win7sp1/`.
- **.NET Framework 4.0** (Revit 2020, 2023 and 2024): `dotNetFx40_Full_x86_x64.exe` from Microsoft.
- **WebView2 runtime** (Revit 2024+): the Evergreen Standalone x64 installer from Microsoft
  (go.microsoft.com/fwlink/?linkid=2124701). Without it the install uses the old runtime from the Revit download,
  and the start screen and Manage Links stay white.
- **Add-ins** (optional): RevitLookup from github.com/lookup-foundation/RevitLookup, pyRevit from
  github.com/pyrevitlabs/pyRevit. Versions as listed above.

## Checksums

After copying, compare with [CHECKSUMS.txt](CHECKSUMS.txt):

```bash
cd installers && shasum -a 256 revit<year>/*
```

A different checksum for a Revit file means a different build from the one we tested. It may still work.

## Disk space

Plan for about 10 GB for the Revit download, about 10 GB more for the unpacked files, and 20–30 GB for the
installed bottle. You can delete `installers/extracted/` after the install.
