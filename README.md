# Revit on Apple Silicon Macs

Run Autodesk Revit (Windows) directly on macOS with [CrossOver](https://www.codeweavers.com/crossover).
No Windows license, no virtual machine. One command builds everything.

## Which versions work

| Revit | Status | Notes |
|---|---|---|
| **2020** | ✅ Works | Real projects: modeling, sheets, exports, PDF printing. [Details](versions/2020.md) |
| **2023** | ⚠️ Mostly works | Modeling, 3D, Materials, saving, PDF, exports, Dynamo (empty node library). [Details](versions/2023.md) |
| **2026** | ⚠️ Mostly works | Modeling, 3D, Materials, saving, pyRevit and RevitLookup. Start screen sometimes redraws. [Details](versions/2026.md) |
| **2027** | ⚠️ Mostly works | Sign-in, new project, modeling, start screen, web panels. Many features not tested yet. [Details](versions/2027.md) |
| 2021, 2022, 2024, 2025 | Not tested yet | |

Tested on an Apple M5 MacBook (16 GB), macOS 26, CrossOver 26.3.

## What you need

- A Mac with Apple Silicon (M1 or newer) and about 45 GB of free disk space.
- [CrossOver](https://www.codeweavers.com/crossover). It is paid, with a free trial.
- [Homebrew](https://brew.sh), then: `brew install sevenzip winetricks cabextract ghostscript python3`
- Your own Revit license and installer from your Autodesk Account.
- One file from any 64-bit Windows 7 or 10 PC: `C:\Windows\System32\msls31.dll`.

Where to put the installer and the extra files: [installers/README.md](installers/README.md).

## Install

```bash
git clone https://github.com/nwmt/revit-macos.git
cd revit-macos
./install.sh 2020        # or 2023, 2026, 2027
```

The script checks everything first and tells you exactly what is missing. Then it builds a
CrossOver bottle with Revit and all fixes (10–30 minutes). When it finishes, start Revit from
`~/Applications/Revit <year> (rvt<year>-a).app` and sign in with your Autodesk account.
Revit 2020, 2023 and 2026 also get a Revit Viewer app next to it.

Want to see the plan first? `INSTALL_DRYRUN=1 ./install.sh 2026` checks and prints, changes nothing.

## Speed

RFO Benchmark (Full_Simplified, average of 3 runs, lower is better) on one Apple M5 MacBook, 16 GB, CrossOver 26.3:

| Revit | Modeling | Graphics |
|---|---:|---:|
| 2020 | 121 s | 25 s |
| 2023 | 116 s | 28 s |
| 2026 | 128 s | 32 s |

Each Revit year has its own benchmark set, so the rows are not comparable with each other. These are our numbers on
one machine, not a promise for yours. Windows reference numbers and caveats are on each version's page.

## Good to know

- This is an independent project. Autodesk does not support Revit on macOS.
  We ship no Autodesk files; you use your own installer and license.
- Something broke? [Troubleshooting](docs/troubleshooting.md). Curious what the fixes do? [How it works](docs/how-it-works.md).
- Tried it on your Mac? Please [open a test report](../../issues/new?template=test-report.yml),
  whether it works or not. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Autodesk and Revit are trademarks of Autodesk, Inc.
