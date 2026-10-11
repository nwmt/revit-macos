# Revit on Apple Silicon Macs

Run Autodesk Revit (Windows) directly on macOS with [CrossOver](https://www.codeweavers.com/crossover).
No Windows license, no virtual machine. One command builds everything.

## Which versions work

| Revit | Status | Notes |
|---|---|---|
| **2020** | ✅ Works | Real projects: modeling, sheets, exports, PDF printing. [Details](versions/2020.md) |
| **2023** | ✅ Works | Modeling, 3D, Materials, PDF, exports, Dynamo, pyRevit and RevitLookup. Dynamo's node list is empty (search works). [Details](versions/2023.md) |
| **2025** | ✅ Works | 2025.5: real project work, Materials, families, saving, exports (PDF, DWG, IFC…), start screen, pyRevit and RevitLookup. [Details](versions/2025.md) |
| **2026** | ⚠️ Mostly works | 2026.5: modeling, 3D, text, Materials, saving, pyRevit and RevitLookup. Start screen sometimes redraws. [Details](versions/2026.md) |
| **2027** | ⚠️ Mostly works | 2027.3: new project, modeling, 3D, text, Materials, web panels. Saving, PDF, add-ins not tested yet. [Details](versions/2027.md) |
| 2021, 2022, 2024 | Not tested yet | |

- ✅ **Works**: the everyday basics work, roughly 90 % or more of what most users need: sign-in, open and save,
  modeling, views and 3D, Materials, printing to PDF, common exports. What's left are minor issues with workarounds.
- ⚠️ **Mostly works**: Revit runs and the core modeling works, but noticeably less than that. Some important features
  are broken or not tested yet.

Tested on an Apple M5 MacBook (16 GB), macOS 26, CrossOver 26.3.

## What you need

- A Mac with Apple Silicon (M1 or newer) and about 45 GB of free disk space.
- [CrossOver](https://www.codeweavers.com/crossover). It is paid, with a free trial.
- [Homebrew](https://brew.sh), then: `brew install sevenzip winetricks cabextract ghostscript python3`
- Your own Revit license and installer from your Autodesk Account. For 2025, 2026 and 2027 the small "Create Installer"
  file is enough: the install downloads Revit and its latest update from Autodesk.
- One file from any 64-bit Windows 7 or 10 PC: `C:\Windows\System32\msls31.dll`.

Where to put the installer and the extra files: [installers/README.md](installers/README.md).

## Install

```bash
git clone https://github.com/nwmt/revit-macos.git
cd revit-macos
./install.sh 2020        # or 2023, 2025, 2026, 2027
```

The script checks everything first and tells you exactly what is missing. Then it builds a
CrossOver bottle with Revit and all fixes (10–30 minutes). When it finishes, start Revit from
`~/Applications/Revit <year> (rvt<year>-a).app` and sign in with your Autodesk account.
Revit 2020, 2023, 2025 and 2026 also get a Revit Viewer app next to it.

Want to see the plan first? `INSTALL_DRYRUN=1 ./install.sh 2026` checks and prints, changes nothing.

## Speed

RFO Benchmark, Full_Simplified, lower is better, on one Apple M5 MacBook (16 GB):

| Revit | Modeling | Graphics |
|---|---:|---:|
| 2020 | 121 s | 25 s |
| 2023 | 115 s | 27 s |
| 2025 | 128 s | 32 s |
| 2026 | 128 s | 32 s |
| 2027 | 99 s | 28 s |

2023, 2025 and 2027 without anti-aliasing, 2020 with it; 2026 was taken with it on and will be re-measured. Method, Windows references and caveats:
[docs/benchmarks.md](docs/benchmarks.md).

## Good to know

- This is an independent project. Autodesk does not support Revit on macOS.
  We ship no Autodesk files; you use your own installer and license.
- Something broke? [Troubleshooting](docs/troubleshooting.md). Curious what the fixes do? [How it works](docs/how-it-works.md).
- Tried it on your Mac? Please [open a test report](../../issues/new?template=test-report.yml),
  whether it works or not. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Autodesk and Revit are trademarks of Autodesk, Inc.
