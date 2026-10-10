# Troubleshooting

Each entry: what you see → what to do. `<bottle>` is the bottle name, for example `rvt2020-a` or `rvt2026-a`.

## Sign-in

**Revit 2020 hangs on the splash screen right after the first sign-in.**
→ Quit Revit and start it again. Sign-in then comes from the cache. If Revit will not quit, stop the bottle:

```bash
WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/<bottle>" \
  /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver -k
```

**Revit 2026 / 2027: you signed in, the browser shows "Opening product" and nothing happens.**
→ The browser must hand the link to the bottle. When it asks which app to use, choose **Autodesk Sign-In (<bottle>)**.
If that app is missing, create it: `./scripts/make-urlhandler.sh <bottle>`.

## Speed

### Revit pauses for about 5 seconds

**Opening a template or changing types stalls for about 5 seconds each time.**
→ Your Mac's own name does not resolve. Add it to `/etc/hosts` (asks for your password):

```bash
H="$(hostname)"; sudo sh -c "printf '127.0.0.1\t$H\n::1\t$H\n' >> /etc/hosts"
```

Measured on Revit 2020. The install script for 2020 warns when the line is missing.

## Web panels (Revit 2026 / 2027)

**Start screen, Manage Links or Project Browser is white, the viewport is slow, a browser process uses a lot of CPU.**
→ The `rvtfix` and `wv2fix` steps are missing. Re-run them: `./scripts/install-odis.sh <year> <bottle> rvtfix wv2fix`.

**Web panels sometimes redraw when another web window opens.**
→ Known issue. Nothing is lost. No fix yet.

**"Autodesk Shared Components bundle is missing" on start.**
→ Re-run the `asc` step: `./scripts/install-odis.sh <year> <bottle> asc`.

**Revit 2027: "default family templates is empty or invalid", no templates.**
→ Re-run the `revitini` step: `./scripts/install-odis.sh 2027 <bottle> revitini`.

## Printing (Revit 2020)

**"You need to install a printer".**
→ Use the **Revit PDF** printer. The install adds it. PDFs go to `~/Documents/Revit-PDF`. It needs Ghostscript:
`brew install ghostscript`.

**Landscape sheets come out rotated on a portrait page.**
→ Known issue. No fix yet.

**"Revit PDF cannot be used with … print settings".**
→ Normal. The file was saved with another computer's printer settings. Continue.

## Add-ins

**Revit 2026: black rectangles appear across Revit after add-ins load.**
→ Turn on software drawing for add-in windows: `REVIT_YEAR=2026 ./scripts/d8-addins.sh <bottle> wpfsw`.
To undo: `... wpfhw`.

**Revit 2020: pyRevit 6.x does not load.**
→ Use pyRevit 4.8.12. `REVIT_YEAR=2020 ./scripts/d8-addins.sh <bottle>` installs it.

**Revit 2020 crashes on start after installing .NET Framework 4.7.2 or 4.8.**
→ Revit 2020 only runs on the .NET 4.7 from its own installer. Rebuild the bottle (see below) and do not install them.

**Enscape: pressing Start crashes Revit.**
→ Not supported: it needs Vulkan features the Mac does not provide. Turn it off:
`REVIT_YEAR=2020 ./scripts/d8-addins.sh <bottle> enscape-off`.

## Dynamo (Revit 2020)

**Dynamo has no 3D background preview.**
→ Expected. It is turned off because it crashes. Graphs and results in Revit work.

## Anything else

**The bottle is in a strange state.**
→ Do not repair it. Delete and rebuild: `CX_RECREATE=1 ./install.sh <year>`.

To see what went wrong, start Revit with logs: `REVIT_YEAR=<year> ./scripts/d7-launch.sh <bottle>`.
Logs land in `logs/`.

## If it doesn't work for you

Revit is not supported on macOS by Autodesk. If this setup does not fit your work, the usual options are:

| Option | Notes |
|---|---|
| Windows 11 on Arm in a virtual machine (Parallels Desktop, VMware Fusion) | Runs on the same Mac. Autodesk does not support this setup either. 16 GB of memory is shared between macOS and Windows. |
| A Windows PC | The supported way. |
| Remote desktop to a Windows PC or a cloud Windows machine | Needs a good network connection. Cloud machines are paid monthly. |
| Autodesk Viewer in a web browser | Enough if you only need to view a model, not edit it. |

Emulators without acceleration (for example UTM/QEMU running x86) are too slow for Revit.
