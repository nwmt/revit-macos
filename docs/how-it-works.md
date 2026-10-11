# How it works

Revit is a Windows x64 program. On an Apple Silicon Mac it runs like this:

- **CrossOver** (a commercial build of Wine) runs Windows programs on macOS. Rosetta 2 translates the x86 code.
  Direct3D 11 goes to Metal (D3DMetal). Direct3D 9 goes through DXVK.
- **One bottle per Revit version.** A bottle is a self-contained Windows 10 environment. A broken bottle is never
  repaired, only rebuilt from scratch.
- **No Autodesk installer.** Autodesk's `Setup.exe` / ODIS installer does not run well under Wine. We unpack the
  download and install the MSI packages directly, one by one, in the order Autodesk's own manifests list them.
  From 2025 on, most of Revit ships as ADIX packages, which we unpack ourselves.
- **Small fixes ("shims") where Wine falls short.** Each one fixes one specific failure. Their sources are in
  `tools/`; GitHub Actions builds them for each release, and `./revit install` downloads that build, checksum-checked.
  A clone whose shim sources differ from the release builds them itself. No Autodesk files are redistributed. Where
  we must change an Autodesk file, we patch a copy inside your bottle.

## What ./revit install does

1. Checks the Mac, CrossOver, the Homebrew tools and the files in `installers/`, and lists everything that is missing.
2. Downloads our prebuilt shims from the project's GitHub release.
3. Downloads Revit and its update from your Create Installer file (2024 and newer).
4. Unpacks the installer on the Mac.
5. Creates the bottle.
6. Runs the steps below.
7. Creates the **Autodesk Sign-In** app for the sign-in link (2024 and newer).
8. Creates the Revit and Revit Viewer apps in `~/Applications`.

## Steps

In install order. Normal install steps have "—" in What breaks.

| Step | What breaks | What we do | Versions |
|---|---|---|---|
| `vc` | — | Microsoft Visual C++ runtimes | all |
| `fonts` | — | Core fonts and MSXML 6 (winetricks) | all |
| `dotnet` | The .NET Framework 4.8 installer refuses to run on "Windows 10" | Install the .NET Revit needs; for 4.8, real 4.0 first, then 4.8 as Windows 7 | all |
| `licensing`, `svcshim` | Licensing service does not start as a Windows service | Install Autodesk licensing; a small wrapper service runs it | all |
| `adsso`, `ssoenv` | Sign-in window loads forever with GPU drawing | Install the AdSSO sign-in window; run it without GPU | 2020, 2023 |
| `idmgr` | — | Autodesk Identity Manager: sign-in through your Mac's browser | 2024+ |
| `rcl`, `ret`, `materials`, `samples` | — | Revit content and extensions, the material library, sample projects | 2020 |
| `rvt` | Autodesk installer (ODIS) | Install Revit's MSI directly; for 2024 the update, a patch to that MSI, is applied while installing it | all |
| `pkgs` | Autodesk installer (ODIS); Steel Connections puts its language files into a wrong folder | Install the other packages directly; move those files into Revit's folder | 2023+ |
| `asc` | "Autodesk Shared Components bundle is missing" on start | Install the Shared Components bundle ourselves | 2026+ |
| `revitini` | 2024, 2025: "Cannot load the required component Autodesk RealDWG Shared", Revit closes. 2027: "Default family templates is empty or invalid" | In `Revit.ini`: where RealDWG is, the language section; defaults for new users (anti-aliasing off, theme to match the Mac) | 2024+ |
| `register` | — | Register Revit with Autodesk licensing, as Autodesk's installer does | all |
| `ncryptshim` | Crash on start and on save (signature check) | Own `ncrypt.dll` for Revit | all |
| `wbemshim` | Crash on New Project and in Options (system info query) | Own WMI wrapper | 2020, 2023, 2024 |
| `webview2` | Built-in web pages fail (old browser runtime) | Install a current WebView2 runtime | 2024+ |
| `d3d9dxvk` | UI, Dynamo and Direct3D 9 panels hang or are unreliable | DXVK for Direct3D 9 | all |
| `dpipatch` | Crash when opening a view (a Windows function Wine lacks) | Patch one import in a copy of the DLL | 2023+ |
| `richedit` | Text in views and dialogs fails; crash on text when creating a project | Microsoft RichEdit DLLs for Revit | all |
| `tlbpin` | Creating views with text is 2–3× slower | Cache for a type library | all |
| `warpshim` | Materials dialog does not open | Software D3D11 device → normal device | all |
| `gdoff` | Generative Design error on start | Turn the add-in off | 2023+ |
| `rvtfix` | Start screen blank or white; 2026+: the browser uses about 60% CPU and the view is slow | Browser draws inside Revit, with flags that make it draw | 2023+ |
| `wv2fix` | The built-in browser (WebView2) crashes on clicks and resizes | Own `version.dll` in the browser process | 2024+ |
| `pdfprinter` | No printer, so Print and Page Setup do not open | **Revit PDF** printer: PostScript → Ghostscript → PDF in `~/Documents/Revit-PDF` | 2020, 2023–2025 |
| `dynamo` | Dynamo's 3D preview draws black squares, lags or crashes | Dynamo without hardware acceleration and background preview | 2020, 2023–2025 |
| `urlhandler` | macOS does not know the link that returns from the browser to Revit: "Opening product" and nothing happens | The **Autodesk Sign-In** app passes the link into the bottle | 2024+ |

Some fixes were carried over from another version as they are, without checking that this version still needs them.

## Add-ins

`./revit addins` installs RevitLookup and pyRevit, then:

| Step | What breaks | What we do |
|---|---|---|
| `trust` | Revit asks "This signed add-in has been found" on every start: under Wine it cannot save **Always Load** | Trust the add-ins' publishers ahead, as **Always Load** would |
| `wpfsw` (2023–2026) | Black rectangles across Revit after add-ins load | WPF draws in software; `wpfhw` turns it back |
| `enscape-off` (not by default) | Pressing Start in Enscape crashes Revit 2020 | Remove the Enscape manifest; `enscape-on` restores it |

## Our shims in tools/

| Tool | What it fixes |
|---|---|
| `tools/svcshim` (2023+), `tools/AdskSvcShim.cs` (2020, built in the bottle) | Autodesk licensing service does not register as a Windows service under Wine. The shim runs as the service and keeps the real one running. |
| `tools/ncrypt-shim` | Revit crashes on start and on save: Wine cannot import or sign with Revit's ECDSA key. The shim does it through Wine's bcrypt. |
| `tools/wbem-shim` | Revit crashes on New Project and in Options: Wine's WMI handles only one async query at a time. The shim runs them one by one. |
| `tools/tlbpin` | Views with text are 2–3× slower: RichEdit reloads a type library for every text element. The shim keeps it cached. |
| `tools/d3d11-warp-shim` | Materials dialog does not open: it asks for a software D3D11 (WARP) device that D3DMetal lacks. The shim gives it the normal device. |
| `tools/rvtfix` | Revit 2026+: crash from a drag-and-drop call on the browser's window, and white web panels with high CPU. Revit 2023–2025: blank start screen (CefSharp). The shim fixes the call and adds browser flags. |
| `tools/wv2fix` | Revit 2024+: the built-in web browser (WebView2) crashes on clicks and resizes. The shim flushes pending drawing before such window changes and skips changes that change nothing. |
| `tools/pdf-printer` | The bottle has no printers. Adds the **Revit PDF** printer; Ghostscript turns its output into PDFs in `~/Documents/Revit-PDF`. |
| `tools/revitini.py` | Writes the `Revit.ini` settings of the `revitini` step (UTF-16, as Revit keeps it). |
| `tools/win_shortcut.py` | Reads the Start Menu shortcuts the installer creates and builds the macOS apps from them, with the same command line and icon. |
| `tools/adsk_sfx.py` | Unpacks Autodesk multi-part downloads (Revit 2020, 2023, the 2024 base release) on the Mac. Their own self-extractor runs out of memory under Wine. |
| `tools/trustpub.py` | Trusts the publishers of the installed add-ins, as **Always Load** would (the `trust` step). |
| `tools/adix.py`, `tools/odis.py` | Read Autodesk's installer manifests and unpack ADIX packages (files and registry) into the bottle, instead of the ODIS installer. |

## Advanced: one step at a time

For normal use, `./revit rebuild <year>` runs everything again from scratch. To rerun single steps in an existing
bottle:

```bash
scripts/install-odis.sh <year> <bottle> <step…>           # Revit 2023 and newer
scripts/d6-install-revit.sh <bottle> <step…>              # Revit 2020
REVIT_YEAR=<year> scripts/d8-addins.sh <bottle> <step…>   # add-ins
```
