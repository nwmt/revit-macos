# Revit on Apple Silicon Macs

Run Autodesk Revit (Windows) directly on macOS with [CrossOver](https://www.codeweavers.com/crossover).
No Windows license, no virtual machine. One command builds everything.

## Which versions work

| Revit | Status | Notes |
|---|---|---|
| **2020** | ✅ Works | Real projects: modeling, sheets, exports, PDF printing (portrait only). Faster than a comparable Windows laptop. [Details](versions/2020.md) |
| **2026** | ⚠️ Mostly works | Modeling, 3D, Materials, saving, pyRevit and RevitLookup. Start screen sometimes redraws. [Details](versions/2026.md) |
| **2027** | ⚠️ Mostly works | Sign-in, new project, modeling, start screen, web panels. Many features not tested yet. [Details](versions/2027.md) |
| 2021–2025 | Not tested yet | |

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
git clone https://github.com/<owner>/revit-macos.git
cd revit-macos
./install.sh 2020        # or 2026, 2027
```

The script checks everything first and tells you exactly what is missing. Then it builds a
CrossOver bottle with Revit and all fixes (10–30 minutes). When it finishes, start Revit from
`~/Applications/Revit <year> (rvt<year>-a).app` and sign in with your Autodesk account.

Want to see the plan first? `INSTALL_DRYRUN=1 ./install.sh 2026` checks and prints, changes nothing.

## Speed

RFO Benchmark for Revit 2020, average of 3 runs, lower is better:

| | Mac (Apple M5, 16 GB) | Windows laptop (Intel i7-10750H, 16 GB) |
|---|---:|---:|
| Modeling | **121 s** | 193 s |
| Graphics | **25 s** | 44 s |

The Windows numbers come from an older run over remote desktop. Treat this as a rough comparison.

## Good to know

- This is an independent project. Autodesk does not support Revit on macOS.
  We ship no Autodesk files; you use your own installer and license.
- Something broke? [Troubleshooting](docs/troubleshooting.md). Curious what the fixes do? [How it works](docs/how-it-works.md).
- Tried it on your Mac? Please [open a test report](../../issues/new?template=test-report.yml),
  whether it works or not. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Autodesk and Revit are trademarks of Autodesk, Inc.
