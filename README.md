# Revit on Apple Silicon Macs

Run Autodesk Revit for Windows on a Mac with [CrossOver](https://www.codeweavers.com/crossover).
No virtual machine, no Windows installation.

## Which versions work

| Revit | Status | Tested on | Main gaps |
|---|---|---|---|
| [2020](versions/2020.md) | ✅ Works | 2020.2 | Dynamo without 3D preview |
| [2023](versions/2023.md) | ✅ Works | 2023.0 | Dynamo node list empty |
| [2024](versions/2024.md) | ✅ Works | 2024.3.6 | First PDF print may produce nothing |
| [2025](versions/2025.md) | ✅ Works | 2025.5 | First PDF print may produce nothing |
| [2026](versions/2026.md) | ⚠️ Mostly works | 2026.5 | PDF, Dynamo, exports not tested |
| [2027](versions/2027.md) | ⚠️ Mostly works | 2027.3 | Online families do not load |
| 2021, 2022 | Not tested | | |

- **Works:** the everyday basics work: sign-in, open and save, modeling, views and 3D, Materials, printing to PDF,
  common exports. What is left are minor issues with workarounds.
- **Mostly works:** Revit runs and modeling works, but some important features are broken or not tested yet.

Worksharing is not tested on any version yet.

Tested on an Apple M5 MacBook (16 GB), macOS 26, CrossOver 26.3. Modeling takes about 1.3–2× as long as on a
fast Windows PC ([benchmarks](docs/benchmarks.md)).

## What you need

- A Mac with Apple Silicon (M1 or newer) and up to 60 GB of free disk space, depending on the version
  ([sizes](installers/README.md#disk-space)).
- [CrossOver](https://www.codeweavers.com/crossover). It is paid, with a free trial.
- Rosetta 2. If it is missing, `./revit install` tells you the command.
- [Homebrew](https://brew.sh). The install steps below set it up.
- Your own Revit license and installer from your Autodesk Account.
- One file from a 64-bit Windows 7 or 10 PC with a Windows license: `C:\Windows\System32\msls31.dll`. A USB stick
  or an email to yourself brings it to the Mac.

## Install

1. Open **Terminal** (Applications → Utilities). Paste each command below and press Return.
2. Install [Homebrew](https://brew.sh): paste the command from its page. It asks for your Mac login password
   (nothing appears while you type) and ends with "Next steps": run the commands listed there. Then:
   ```bash
   brew install sevenzip winetricks cabextract python3
   ```
3. Download this project into your home folder:
   ```bash
   git clone https://github.com/nwmt/revit-macos.git
   cd revit-macos
   ```
4. Put the Revit installer and the extra files into `installers/` ([what goes where](installers/README.md)).
   To open the folder in Finder: `open installers`
5. Install, for example Revit 2025:
   ```bash
   ./revit install 2025
   ```

The script first checks everything and tells you what is missing. Then it installs Revit and all fixes into a
**bottle**: a separate Windows environment that CrossOver keeps for one Revit version. The bottle for Revit 2025 is
named `rvt2025-a`. This takes 10–30 minutes, plus the time to download Revit (11–15 GB) for 2024 and newer. Keep the
Mac plugged in and Terminal open.

Revit appears in the Applications folder of your home folder (in Finder: Go → Home → Applications), for example
**Revit 2025 (rvt2025-a)**. Revit 2026 and older also get Revit Viewer there; Revit 2027 has no Viewer mode.

## First launch

- **Revit 2020, 2023:** sign in in Revit's own window. If Revit then hangs on the splash screen, quit it and start it again.
- **Revit 2024 and newer:** Revit opens the Autodesk sign-in page in your browser. After you sign in, the browser
  asks which app should open the link. Choose **Autodesk Sign-In (rvt2025-a)**, named after the bottle.

## Commands

Run them in Terminal, in the project folder. In a new Terminal window, first type `cd revit-macos`.

| Command | What it does |
|---|---|
| `./revit install 2025` | Install Revit 2025 |
| `./revit check 2025` | Before an install: check what it needs, change nothing |
| `./revit doctor 2025` | Check an installed Revit, its bottle and this Mac; change nothing |
| `./revit addins 2025` | Add RevitLookup and pyRevit, with the fixes add-ins need (2020, 2023–2027) |
| `./revit addins 2025 --only pdfprinter` | Add only the add-ins named (comma-separated), here the **Revit PDF** printer. It needs Ghostscript: `brew install ghostscript` |
| `./revit addins list 2025` | List the add-ins for Revit 2025 |
| `./revit stop 2025` | Quit a Revit that hangs |
| `./revit logs 2025` | List the newest logs |
| `./revit debug 2025` | Start Revit and record a log |
| `./revit report 2025` | Make a report for a GitHub issue, with personal data removed |
| `./revit rebuild 2025` | Delete the bottle and install Revit again |
| `./revit remove 2025` | Delete Revit, its bottle and its apps |
| `./revit status` | List the Revit bottles on this Mac |
| `./revit find-installer ~/Downloads/Revit` | Say which Revit installer a folder holds |
| `./revit link-installer 2025 ~/Downloads/Revit` | Install Revit 2025 from that folder instead of `installers/revit2025/` |
| `./revit import msls31 <file>` | Add msls31.dll from your Windows PC |
| `./revit cache` | Show or clear installer files |

`rebuild` and `remove` show what they delete and ask you to type the year first.

## Updating

- **This project:** `git pull`. Your installed Revit keeps working. New fixes reach it after `./revit rebuild 2025`.
- **A newer Revit update (2024 and newer):** each Create Installer file names one Revit update. Download a new
  one from your Autodesk Account and put it into `installers/revit2025/` instead of the old one. Delete the folder
  `installers/extracted/revit2025` (it holds the old unpacked files). Then run `./revit rebuild 2025`: it downloads
  the new update and installs it.
- `rebuild` and `remove` reset Revit's settings and add-ins in the bottle. Your projects in Documents stay.

## Good to know

- **Your files:** the Documents folder in Revit is your Mac's Documents folder. Files saved anywhere else on the
  bottle's C: drive are deleted by `rebuild` and `remove`.
- **Look:** Revit 2024 and newer start with anti-aliasing off (Revit runs better without it) and a dark or light
  theme to match your Mac at install time. Change both in Revit's Options, or pick the theme at install:
  `REVIT_THEME=dark ./revit install 2025` (or `light`).
- **Something broke?** See [Troubleshooting](docs/troubleshooting.md). Curious what the fixes do?
  See [How it works](docs/how-it-works.md).
- **Tried it on your Mac?** Please [open a test report](../../issues/new?template=test-report.yml), whether it
  works or not.

## License

[MIT](LICENSE). This is an independent project, not affiliated with Autodesk. Autodesk does not support Revit on
macOS. The project ships no Autodesk or Microsoft files: you use your own Revit installer and license. Which
Microsoft components an install puts into the bottle, and where each comes from:
[Microsoft components](docs/how-it-works.md#microsoft-components). Autodesk and Revit are trademarks of Autodesk, Inc.
