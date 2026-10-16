# Troubleshooting

Find what you see. Each entry says which Revit versions it applies to. `<year>` is your Revit year, for example 2025;
`<bottle>` is its bottle, for example `rvt2025-a`. Run the commands in Terminal, in the project folder.

## First

### Check the setup

All versions

**Solution:** `./revit doctor <year>`. It checks this Mac, CrossOver and the bottle, changes nothing and lists each
problem with what to do. `./revit doctor` without a year checks only the Mac and CrossOver.

### Start over

All versions

**Solution:** `./revit rebuild <year>`. It deletes the bottle and installs Revit into it again. Revit's settings and
add-ins in the bottle are reset; your projects in Documents stay. See [Updating](../README.md#updating).

### Revit hangs

All versions

**Solution:** `./revit stop <year>`. It quits Revit and everything else in its bottle. Unsaved changes are lost.

### Report a problem

All versions

1. If Revit fails when it starts or while you work: run `./revit debug <year>`, make the problem happen, and quit
   Revit. A failed `./revit install` already left its logs.
2. Run `./revit report <year>`. It writes `report.txt` and `report.zip` and prints where they are.
3. Read both before you post them.
4. [Open a test report](https://github.com/nwmt/revit-macos/issues/new?template=test-report.yml): paste `report.txt`,
   attach `report.zip`.

To remove personal data, `./revit report` reads your Mac user name, computer name and serial number, and the Autodesk
user name and ID that Revit keeps in the bottle (Revit.ini, journals). It keeps them in memory only and puts
placeholders such as `<USER>` in their place. It never opens sign-in, licensing or browser data, and uploads nothing.
It removes what it recognizes. A file it cannot clean is left out, and `report.txt` says so.

A Revit bug that also happens on Windows goes to Autodesk. A CrossOver problem that also happens in other apps goes
to CodeWeavers.

## Install

### Install stops: "the Autodesk licensing service does not answer"

All versions

**Solution:** `./revit rebuild <year>`. If it stops there again, [report a problem](#report-a-problem).

## Start

### Revit does not start from ~/Applications, nothing happens

All versions

Often after a macOS upgrade: Rosetta 2 is gone, and the Revit app fails without a message.

**Solution:** `./revit doctor <year>` names the cause. If it says Rosetta 2 is missing:
`softwareupdate --install-rosetta --agree-to-license`.

## Sign-in

### Revit hangs on the splash screen after the first sign-in

Revit 2020, 2023

**Solution:** Quit Revit and start it again. Sign-in then comes from the cache. If Revit does not quit:
`./revit stop <year>`.

### After sign-in the browser shows "Opening product" and nothing happens

Revit 2024 and newer

**Solution:** The browser must hand the link to the bottle. When it asks which app to use, choose
**Autodesk Sign-In (rvt2025-a)**, with your bottle's name. If that app is missing: `./revit rebuild <year>`.

## Speed

### Revit pauses for about 5 seconds

All versions (measured on Revit 2020)

Opening a template or changing types stalls for about 5 seconds each time: your Mac's own name does not resolve.

**Solution:** Add it to `/etc/hosts`. The command asks for your Mac login password; nothing appears while you type.

```bash
H="$(hostname)"; sudo sh -c "printf '127.0.0.1\t$H\n::1\t$H\n' >> /etc/hosts"
```

`./revit install` warns when the line is missing.

## Web panels

### Start screen, Manage Links or Project Browser is white, a browser process uses a lot of CPU

Revit 2023 and newer

**Solution:** `./revit rebuild <year>`: the fixes for the built-in browser are part of `./revit install`. For 2024 and
newer it also downloads a fresh WebView2 runtime; if that download failed, the install said "no fresh WebView2
runtime". Then check the internet connection and rebuild again.

### Web panels sometimes redraw when another web window opens

Revit 2026, 2027

Known issue. Nothing is lost. No fix yet.

### "Autodesk Shared Components bundle is missing" on start

Revit 2026, 2027

**Solution:** `./revit rebuild <year>`.

### "Default family templates is empty or invalid", no templates

Revit 2027

**Solution:** `./revit rebuild 2027`.

## Printing

### "You need to install a printer"

Revit 2020, 2023, 2024, 2025

**Solution:** Use the **Revit PDF** printer: `brew install ghostscript`, then `./revit addins 2025 --only pdfprinter`.
PDFs go to `~/Documents/Revit-PDF`.

### "Revit PDF cannot be used with … print settings"

Revit 2020, 2023, 2024, 2025

Normal: the file was saved with another computer's printer settings. Continue.

### The first print to Revit PDF produces nothing

Revit 2024, 2025

**Solution:** Print again.

## Add-ins

### Black rectangles appear across Revit after add-ins load

Revit 2023, 2024, 2025, 2026

**Solution:** `./revit addins <year>`. It turns on software drawing for Revit's windows, along with the add-ins.

<details>
<summary>Advanced: turn software drawing off again</summary>

```bash
./scripts/run-steps.sh <year> <bottle> wpfhw
```

</details>

### Revit asks "This signed add-in has been found" on every start

Revit 2020, 2023, 2024, 2025, 2026

In CrossOver, Revit cannot save the **Always Load** answer.

**Solution:** `./revit addins <year>`. It trusts the publishers of the add-ins in your Addins folder, as
**Always Load** would.

### pyRevit 6.x does not load

Revit 2020

**Solution:** Use pyRevit 4.8.12: `./revit addins 2020` installs it.

### Revit 2020 crashes on start after installing .NET Framework 4.7.2 or 4.8

Revit 2020

Revit 2020 only runs on the .NET 4.7 from its own installer.

**Solution:** `./revit rebuild 2020`, and do not install them again.

### Pressing Start in Enscape crashes Revit

Tested on Revit 2020; other versions are not tested.

Enscape needs graphics features that CrossOver on a Mac does not have. The `enscape` step installs Enscape 3.4.4
together with fixes that give it what it needs.

**Solution:** put the installer in place ([where](../installers/README.md#add-ins-optional)) and run
`./scripts/run-steps.sh 2020 rvt2020-a enscape trust`. If Enscape is already installed, this installs it
again with the fixes.

<details>
<summary>Advanced: turn Enscape off so it does not load</summary>

```bash
./scripts/run-steps.sh 2020 rvt2020-a enscape-off
```

</details>

## Dynamo

### Dynamo has no 3D background preview

Revit 2020, 2023, 2024, 2025

Expected: it is turned off, because with it Dynamo draws black squares, lags or crashes. Graphs run and results show
in Revit views.

## If it does not work for you

Autodesk does not support Revit on macOS. If this setup does not fit your work, the usual options are:

| Option | Notes |
|---|---|
| Windows 11 on Arm in a virtual machine (Parallels Desktop, VMware Fusion) | Runs on the same Mac. Autodesk does not support this setup either. 16 GB of memory is shared between macOS and Windows. |
| A Windows PC | The supported way. |
| Remote desktop to a Windows PC or a cloud Windows machine | Needs a good network connection. Cloud machines are paid monthly. |
| Autodesk Viewer in a web browser | Enough if you only need to view a model, not edit it. |

Emulators without acceleration (for example UTM/QEMU running x86) are too slow for Revit.
