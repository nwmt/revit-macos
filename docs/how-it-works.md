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
  `tools/shims/`; GitHub Actions builds them for each release, and `./revit install` downloads that build, checksum-checked.
  A clone whose shim sources differ from the release builds them itself. No Autodesk files are redistributed, and
  no Autodesk EXE or DLL is changed: fixes inside Revit's own DLLs are made in memory by `tools/shims/rvtfix`. The steps
  below do change Revit's settings and add-ins, but not Autodesk's installer packages.

## What ./revit install does

1. Checks the Mac, CrossOver, the Homebrew tools and the files in `installers/`, and lists everything that is missing.
2. Downloads our prebuilt shims from the project's GitHub release, and the Microsoft runtimes the version needs
   ([Microsoft components](#microsoft-components)).
3. Downloads Revit and its update from your Create Installer file (2024 and newer).
4. Unpacks the installer on the Mac.
5. Creates the bottle.
6. Runs the steps below.
7. Creates the **Autodesk Sign-In** app for the sign-in link (2024 and newer).
8. Creates the Revit app in `~/Applications`, and the Revit Viewer app when the installer made its Start Menu
   shortcut (2026 and older).

Each install and `./revit addins` run adds one line to `revit-macos/runs.ndjson` in the bottle: the steps, the result,
the CrossOver build, the project version, the shims, the Revit build the installer names and the unpacked installer
folder the steps read. `./revit doctor` reads it. `./revit remove`, `./revit cache` and `--reextract` keep an unpacked
folder while another bottle of its year may install from it: its record names that folder, or does not say (no install
record, or one from before that field).

The Revit app and `./revit debug` start the bottle's Wine server (wineserver) first, through `scripts/watch-server.pl`
(the app runs a copy in the bottle's `revit-macos` folder). It writes the server's messages to
`revit-macos/wineserver.log` and how the server ended to `wineserver.last`. `./revit doctor` says when it ended
unexpectedly, and `./revit report` includes both files.

## Steps

In install order. Normal install steps have "—" in What breaks.

| Step | What breaks | What we do | Versions |
|---|---|---|---|
| `vc` | — | Microsoft Visual C++ runtimes | all |
| `fonts` | — | Core fonts and MSXML 6 (winetricks) | all |
| `netfx` | The .NET Framework 4.8 installer refuses to run on "Windows 10" | Real .NET Framework 4.0 first, then 4.8 from Revit's installer as Windows 7 | 2021, 2023, 2024 (2020: 4.7 the same way) |
| `dotnet` | Revit 2025 and newer run on .NET 8 or 10 | Every .NET runtime Revit's installer ships | 2025, 2026, 2027 |
| `licensing`, `svcshim` | Licensing service does not start as a Windows service | Install Autodesk licensing; a small wrapper service runs it | all |
| `adsso`, `ssoenv` | Sign-in window loads forever with GPU drawing | Install the AdSSO sign-in window; run it without GPU | 2020, 2021, 2023 |
| `idmgr` | — | Autodesk Identity Manager: sign-in through your Mac's browser | 2024+ |
| `rcl`, `ret`, `materials`, `samples` | — | Revit content and extensions, the material library, sample projects | 2020 |
| `rvt` | Autodesk installer (ODIS); Revit's MSI fails if the licensing service does not answer | Install Revit's MSI directly. We run its licensing-service check first and stop with that check's log if it fails. For 2024 the update, a patch to that MSI, is applied while installing it | all |
| `pkgs` | Autodesk installer (ODIS); Steel Connections puts its language files into a wrong folder | Install the other packages directly; move those files into Revit's folder | 2023+ |
| `asc` | "Autodesk Shared Components bundle is missing" on start | Install the Shared Components bundle ourselves | 2026+ |
| `revitini` | 2024, 2025: "Cannot load the required component Autodesk RealDWG Shared", Revit closes. 2027: "Default family templates is empty or invalid" | In `Revit.ini`: where RealDWG is, the language section; defaults for new users (anti-aliasing off; 2024–2026: the theme to match the Mac) | 2024+ |
| `register` | — | Register Revit with Autodesk licensing, as Autodesk's installer does | all |
| `ncryptshim` | Crash on start and on save (signature check) | Own `ncrypt.dll` for Revit | all |
| `wbemshim` | Crash on New Project and in Options (system info query) | Own WMI wrapper | 2020, 2021, 2023, 2024 |
| `webview2` | Built-in web pages fail (old browser runtime) | Install a current WebView2 runtime | 2024+ |
| `d3d9dxvk` | UI, Dynamo and Direct3D 9 panels hang or are unreliable | DXVK for Direct3D 9 | all |
| `richedit` | Text in views and dialogs fails; crash on text when creating a project | Microsoft RichEdit DLLs for Revit | all |
| `tlbpin` | Creating views with text is 2–3× slower; long edits poll the mouse slowly | Cache for a type library and for the cursor position | all |
| `warpshim` | Materials dialog does not open; its previews crash (`AdPreviewGenerator.exe`) | Software D3D11 device → normal device, through `tools/shims/rvtfix`, in Revit and in the preview process (loaded there by `tools/shims/wv2fix`) | all |
| `gdoff` | Generative Design error on start | Turn the add-in off | 2023+ |
| `rvtfix` | Start screen blank or white; 2026+: the browser uses about 60% CPU and the view is slow; crash when opening a view (a Windows function Wine lacks); 2027: Dynamo crashes when its start window closes; 2027: maximize on a second display puts Revit on the main display | Browser draws inside Revit, with flags that make it draw; the missing function answered in memory; the browser's window is moved out before Revit destroys the window it sits in; Revit's maximized position for a second display is moved onto that display | 2023+ (2020, 2021: for `warpshim`) |
| `wv2fix` | The built-in browser (WebView2) crashes on clicks and resizes | Own `version.dll` in the browser process | 2024+ |
| `downloads` | Insert → Load Autodesk Family stops at 100%: the browser saves the family into Downloads first, and macOS does not let it list the Mac's `~/Downloads` | Windows' Downloads folder moves into the bottle; the Mac's folder is not touched | 2026, 2027 |
| `retina`, `mackeys` | Text and drawings are blurry on a Retina screen; Cmd works as Alt, so Cmd+S opens a ribbon tab | Retina mode at 192 DPI; Cmd works as Ctrl, left Option as Alt. `./revit set` turns them off | 2027 |
| `theme` | Revit keeps the theme it got at install: Wine does not pass the Mac's light or dark look to Windows | Revit follows the Windows theme. Our `themeset.exe` in the bottle sets it to the Mac's look before the Revit app starts Revit, and the menu bar app sets it again when the Mac's look changes; Revit repaints. `./revit set 2027 theme=dark` keeps one theme | 2027 |
| `pdfprinter` (an add-in: `./revit addins <year> --only pdfprinter`) | No printer, so Print and Page Setup do not open | **Revit PDF** printer: PostScript → Ghostscript → PDF in `~/Documents/Revit-PDF` | 2020, 2021, 2023–2025 (2026: not tested) |
| `dynamo` | Dynamo's 3D preview draws black squares, lags or crashes | Dynamo without hardware acceleration and background preview; 2027: Dynamo does not wait on its start window, which stays white | 2020, 2021, 2023–2025, 2027 |
| `revitmcp`, `revitmcp_experimental` (an add-in: [docs/mcp.md](mcp.md)) | Autodesk's MCP Server finds Revit by listing named pipes, which Wine cannot list; its add-in quits without Autodesk analytics (ADP) | The server's MSI, and ADP from Revit's installer, only with this add-in. `./revit mcp` starts the server through our launcher (`tools/shims/mcphost`), which loads `tools/shims/mcppipes` into it: the pipe listing reads a folder of marker files that the launcher keeps from the names of Revit's open pipes | 2027 |
| `urlhandler` | macOS does not know the link that returns from the browser to Revit: "Opening product" and nothing happens | The **Autodesk Sign-In** app passes the link into the bottle | 2024+ |

Some fixes were carried over from another version as they are, without checking that this version still needs them.

## Microsoft components

The project ships no Microsoft files. `./revit install` puts these into the bottle:

| Component | Comes from | Step |
|---|---|---|
| Visual C++ runtimes; .NET Framework 4.7 (2020) and 4.8 (2021, 2023, 2024); .NET 8 and 10 (2025+) | Revit's installer, which ships them | `vc`, `netfx`, `dotnet` |
| .NET Framework 4.0 (2020, 2021, 2023, 2024) | Microsoft's offline installer from Microsoft's download server: the same file and checksum winetricks uses | `netfx` |
| WebView2 runtime (2024+) | Microsoft's installer for the newest build, from Microsoft's download link; if that download fails, the older one in Revit's installer | `webview2` |
| Core fonts, MSXML 6 | winetricks downloads them from their usual sources | `fonts` |
| `riched20.dll`, `msftedit.dll`, `usp10.dll` | The Windows 7 SP1 update package (KB976932) from Microsoft's download server: the same file and checksum winetricks uses | `richedit` |
| `msls31.dll` | A 64-bit Windows 7 or 10 PC with a Windows license ([what you need](../README.md#what-you-need)) | `richedit` |

The last two rows are parts of Windows, not runtimes made for redistribution. Microsoft's license terms for Windows
apply to them.

## Add-ins

`./revit addins` installs RevitLookup and pyRevit, then the steps below. Each add-in is a file in `scripts/addins/`
(name, the files per year with their URL and SHA-256, the step that installs it, its EULA); `--only` picks add-ins from
there and adds the steps they need.

| Step | What breaks | What we do |
|---|---|---|
| `trust` | Revit asks "This signed add-in has been found" on every start: under Wine it cannot save **Always Load** | Trust the add-ins' publishers ahead, as **Always Load** would |
| `wpfsw` (2023–2027) | Black rectangles across Revit after add-ins load | WPF draws in software; `wpfhw` turns it back |
| `enscape` (not by default; 2020) | Pressing Start in Enscape 3.4.4 crashes Revit; once past that, black models, a hang when its window is resized, and keys and mouse that do not move the view | Install Enscape with a `System.ValueTuple` that fits .NET 4.7; `tools/shims/vkshim` as `vulkan-1.dll` in `system32`, loaded by Revit.exe only; Metal argument buffers and synchronous queue submits in MoltenVK, set in the bottle's environment |
| `enscape` (not by default; 2027) | Enscape 4.18 turns down the Mac GPU, and its license check cannot read the computer ID (no `wminet_utils.dll`); then its menus hang it, Asset Library stays blank, and the Chaos sign-in and Asset Library services do not start | Install Enscape without its UI; `wminet_utils.dll` (for the computer ID) from the .NET 4.8 installer Enscape ships; for `Enscape.RendererHost.exe`: `tools/shims/vkshim` as `vulkan-1.dll`, no `d3d11` (its interface draws in software), `tools/shims/wv2fix` loading `tools/shims/rvtfix` for its browser; the MoltenVK settings as for 2020; the two Chaos services through `tools/shims/svcshim` |
| `enscape-off` (not by default) | — | Remove the Enscape manifest so Enscape does not load; `enscape-on` restores it |

## For the menu bar app

`./revit` is also the engine of the menu bar app. One lock, in `~/Library/Application Support/revit-macos/`, keeps two
tasks from changing the same bottles at once, from any copy of the project and from the app. `REVIT_DATA` moves
installers, unpacked files and logs out of the project folder. With `--events <folder>` a command writes its progress as
JSON lines to `<folder>/events.ndjson`, ending with one `end` line that carries the result. `./revit status --json`,
`./revit find-installer <folder> --json` and `./revit addins list <year> --json` answer the app's questions;
`./revit remove` and `rebuild` with `--dry-run --json` say what they would delete, and `./revit import msls31 <file>`
copies the one Windows file the app asks for. `./revit cache` lists the downloaded and unpacked installer files that
can be deleted (never an installer folder of yours, nor a file an installer still reads), and `cache clear --yes`
deletes them. When a step or an action fails, its log's last lines go to the events as an error message, and the
`end` line's `reason` says when the cause was a download or the disk space.

Inside the app the engine lives in `Contents/Resources/engine` and runs read-only: it keeps installers, unpacked files
and logs in `~/Library/Application Support/<app name>`, and uses only the tools the app brings (7-Zip, cabextract,
winetricks, Python) and its own copy of the shims. Nothing it writes into a bottle or `~/Applications` points into the
app, so moving the app breaks nothing. `scripts/check-bundle.sh` checks the app's tools and shims.

The app does nothing itself that the engine does: it runs `revit` from its bundle for every question (with `--json`)
and every task. A task runs with `--events` in a new folder under `<data>/logs/runs/`, in a session of its own, so it
goes on when the app quits and the app finds it again when it opens. Cancel sends the task's process group the signal
Ctrl-C sends in Terminal, and only to a task the app started.

**Trackpad in Revit** (a switch in the app's Settings, off at first): in Revit's views two fingers pan, Shift and two
fingers orbit, a pinch zooms; everywhere else scrolling stays scrolling, and mouse wheels are not touched. Wine passes
no middle button and no pinch, so a helper app inside the app, `<app name> Trackpad`, turns the trackpad's gestures
into a middle-button drag and the scroll wheel. It needs the permission in System Settings → Privacy & Security →
Device Control and Data Access, and has it alone: nothing the app or the helper starts gets it. macOS sees all of
Revit as one window, so the helper asks `./revit hittest` (our `hittest.exe` in the bottle) which Windows window is
under the cursor when a gesture starts: only Revit's views pan and zoom, lists, Properties, the Project Browser and
schedules keep scrolling. Checked on Revit 2027; in other years the gestures stay scrolling. The helper keeps a log in
`<data>/logs/trackpad.log` (no window titles, no positions), which the diagnostic report includes.

## Our shims in tools/

| Tool | What it fixes |
|---|---|
| `tools/shims/svcshim` | Autodesk licensing service does not register as a Windows service under Wine. The shim runs as the service and keeps the real one running (for Revit 2020 from the licensing service's version folder: that service takes its version from the folder's name). For Enscape 4.18 (2027) it runs Chaos sign-in and Asset Library as services, so they start with the bottle. |
| `tools/shims/ncryptshim` | Revit crashes on start and on save: Wine cannot import or sign with Revit's ECDSA key. The shim does it through Wine's bcrypt. |
| `tools/shims/wbemshim` | Revit crashes on New Project and in Options: Wine's WMI handles only one async query at a time. The shim runs them one by one. |
| `tools/shims/tlbpin` | Views with text are 2–3× slower: RichEdit reloads a type library for every text element. Long edits check the mouse hundreds of thousands of times, and while the mouse is still each check asks macOS (~12 us instead of under 1 us). The shim caches the type library and reuses the cursor position for 10 ms. |
| `tools/shims/d3dwp` | Materials dialog does not open: it asks for a software D3D11 (WARP) device that D3DMetal lacks. The shim gives it the normal device. |
| `tools/shims/rvtfix` | Revit 2026+: crash from a drag-and-drop call on the browser's window, and white web panels with high CPU. Revit 2023–2025: blank start screen (CefSharp). Revit 2023+: crash when opening a view (a Windows function Wine lacks). The shim fixes the call, adds browser flags, answers the missing function and points Revit's graphics DLL at `tools/shims/d3dwp`, all in memory: Revit's files stay as installed. Revit 2027: maximize on a second display puts Revit on the main display; the shim moves the position Revit gives for that display onto it. Enscape 4.18 (2027) gets the same browser flags for its Asset Library. |
| `tools/shims/wv2fix` | Revit 2024+: the built-in web browser (WebView2) crashes on clicks and resizes. The shim flushes pending drawing before such window changes and skips changes that change nothing. In Enscape 4.18 (2027) it loads `tools/shims/rvtfix` as soon as Enscape starts. |
| `tools/shims/vkshim` | Enscape 3.4.4 in Revit 2020 and 4.18 in 2027: Enscape turns down the Mac GPU (it asks for a Windows memory-sharing extension and a blend feature that MoltenVK lacks), creates a query type that MoltenVK refuses, and under Wine its view never gets the keyboard focus. The shim reports the missing pieces, gives it a query type MoltenVK has, and on a click activates Enscape's view as Windows does. DXVK, which draws Revit's own interface, sees Vulkan unchanged. |
| `tools/shims/hittest` | macOS sees Revit as one window and Wine tells no other process which Windows window is under the cursor. For the app's trackpad gestures it answers, for a point, the window there and its parents (class and title), until Revit ends. |
| `tools/shims/pdfprinter` | The bottle has no printers. Adds the **Revit PDF** printer; Ghostscript turns its output into PDFs in `~/Documents/Revit-PDF`. |
| `tools/revitini.py` | Writes the `Revit.ini` settings of the `revitini` step (UTF-16, as Revit keeps it). |
| `tools/win_shortcut.py` | Reads the Start Menu shortcuts the installer creates and builds the macOS apps from them, with the same command line and icon. |
| `tools/adsk_sfx.py` | Unpacks Autodesk multi-part downloads (Revit 2020, 2021, 2023, the 2024 base release) on the Mac. Their own self-extractor runs out of memory under Wine. |
| `tools/trustpub.py` | Trusts the publishers of the installed add-ins, as **Always Load** would (the `trust` step). |
| `tools/adix.py`, `tools/odis.py` | Read Autodesk's installer manifests and unpack ADIX packages (files and registry) into the bottle, instead of the ODIS installer. |

Each shim builds with `scripts/build-shims.sh <name>` into `build/<name>/`.

## Advanced: one step at a time

For normal use, `./revit rebuild <year>` runs everything again from scratch. To rerun single steps in an existing
bottle:

```bash
scripts/run-steps.sh <year> <bottle> <step…>   # install and add-in steps
```

Each run writes its logs to `logs/<bottle>/<time>-steps/`: one log per step and `summary.txt`.
