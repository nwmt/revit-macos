# How it works

Revit is a Windows x64 program. On an Apple Silicon Mac it runs like this:

- **CrossOver** (a commercial build of Wine) runs Windows programs on macOS. Rosetta 2 translates the x86 code.
  Direct3D 11 goes to Metal (D3DMetal). Direct3D 9 goes through DXVK.
- **One bottle per Revit version.** A bottle is a self-contained fake Windows 10 drive. A broken bottle is never
  repaired, only rebuilt from scratch by the scripts.
- **No Autodesk installer.** Autodesk's `Setup.exe` / ODIS installer does not run well under Wine. We unpack the
  download and install the MSI packages directly, one by one, in the order Autodesk's own manifests list them.
  From 2026 on, most of Revit ships as ADIX packages, which we unpack ourselves.
- **Small fixes ("shims") where Wine falls short.** Each one fixes one specific failure. They are built from source
  in `tools/` during install. No Autodesk files are redistributed. Where we must change an Autodesk file, we patch a
  copy inside your bottle.

## Our shims

| Tool | What it fixes |
|---|---|
| `tools/svcshim` (2026+), `tools/AdskSvcShim.cs` (2020) | Autodesk licensing service does not register as a Windows service under Wine. The shim runs as the service and keeps the real one running. |
| `tools/ncrypt-shim` | Revit crashes on start and on save: Wine cannot import or sign with Revit's ECDSA key. The shim does it through Wine's bcrypt. |
| `tools/wbem-shim` | Revit 2020 crashes on New Project and in Options: Wine's WMI handles only one async query at a time. The shim runs them one by one. |
| `tools/tlbpin` | Views with text are 2–3× slower: RichEdit reloads a type library for every text element. The shim keeps it cached. |
| `tools/d3d11-warp-shim` | Materials dialog does not open: it asks for a software D3D11 (WARP) device that D3DMetal lacks. The shim gives it the normal device. |
| `tools/rvtfix` | Revit 2026+: crash from a drag-and-drop call on the browser's window, and white web panels with high CPU. Revit 2023: blank start screen. The shim fixes the call and adds browser flags. |
| `tools/wv2fix` | Revit 2026+: the built-in web browser (WebView2) crashes on clicks and resizes. The shim flushes pending drawing before such window changes and skips changes that change nothing. |
| `tools/pdf-printer` | The bottle has no printers. Adds a "Revit PDF" printer; Ghostscript turns its output into PDFs in `~/Documents/Revit-PDF`. |
| `tools/win_shortcut.py` | Reads the Start Menu shortcuts the installer creates and builds the macOS apps from them, with the same command line and icon. |
| `tools/adsk_sfx.py` | Unpacks Autodesk multi-part downloads (Revit 2020) on the Mac. Their own self-extractor runs out of memory under Wine. |
| `tools/adix.py`, `tools/odis.py` | Read Autodesk's installer manifests and unpack ADIX packages (files and registry) into the bottle, instead of the ODIS installer. |

Other steps use Microsoft or open-source components: RichEdit DLLs for text, DXVK for Direct3D 9, a current WebView2
runtime. The full step list for each version is on its page in [versions/](../versions/).
