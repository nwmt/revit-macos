#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""./revit doctor: what is wrong with this Mac, CrossOver and a Revit bottle, read from files only.

  doctor.py --root R --data D --cx CX --bottles B [--shims S] [--lock F] [--cx-tested V] [--engine E]
            [--shims-release V] [--year Y --bottle N --profile-json F|-] [--addins JSON] [--json] [--all]

It never starts wine, wineserver or cxbottle (the first wine after a CrossOver update upgrades the bottle), takes no
lock and writes nothing. collect() reads the facts: sysctl, sw_vers, arch, osascript (free space), lsof (whether
anything runs in the bottle), osadecompile (what the apps start), CrossOver's files, the bottle through bottleread,
its run record through runlog, the unpacked installer's .source through installer_drift. run_checks() makes the
checks from the facts alone (tests give it synthetic ones); render() prints them.

The logs group reads the newest logs of the bottle through tools/signatures.py: the newest debug session
(logs/<bottle>/<time>-debug: wine.cxlog, stdout.log), the newest install, steps or add-ins run (its step logs and MSI
logs) and Revit's newest journal in the bottle; never a log older than the bottle's last install (its run record). A
known failure there is a warning with the date of the session it was seen in, never a ✗; counts are in the JSON only.

Output: the problems as ./revit check prints them ("  ✗ title" or "  ! title", then "      fix: what to do"), notes
("  · title"), then "  ✓ no problems found (N checks)"; --all adds the checks that passed. --json:
  {"checks": [{"id", "group", "status": "ok|warn|fail|info", "title", "detail", "fix", "doc"}],
   "summary": {"fail", "warn", "ok", "info", "checks"}}
Versions of CrossOver's parts, the compatibility database's sha256 and similar details are in the JSON only.
Exit: 1 when a check failed, else 0; 2 for bad arguments. ./revit doctor passes the arguments; the year's profile
comes from profile_json in scripts/lib/common.sh. Run with python3 -I -B.
"""
import argparse
import calendar
import fcntl
import glob
import hashlib
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bottleread  # noqa: E402
import runlog  # noqa: E402
import signatures  # noqa: E402

GROUPS = ("host", "crossover", "bottles", "bottle", "install", "fixes", "settings", "addins", "mcp", "logs")
S32 = "drive_c/windows/system32"
AL = "drive_c/Program Files (x86)/Common Files/Autodesk Shared/AdskLicensing"
WV2 = "drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
NETFX_DIR = "drive_c/windows/Microsoft.NET/Framework64/v4.0.30319"
DESKTOP = "drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App"
DOCUMENTS = "drive_c/users/crossover/Documents"
NDP_KEY = "Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full"
# the steps retina and mackeys (scripts/steps/fixes.sh): settings, not fixes. Wine reads RetinaMode from MAC_DRIVER, the
# keys from Revit.exe's AppDefaults first, LogPixels from DESKTOP_KEY (user.reg), then FONTS_HKLM (system.reg), then 96
SETTING_STEPS = ("retina", "mackeys")
MAC_DRIVER = "Software\\Wine\\Mac Driver"
MAC_DRIVER_APP = "Software\\Wine\\AppDefaults\\Revit.exe\\Mac Driver"
DESKTOP_KEY = "Control Panel\\Desktop"
FONTS_HKLM = "System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts"
KEY_VALUES = ("leftcommandisctrl", "rightcommandisctrl", "leftoptionisalt")
RETINA = {("y", 192): "on", ("y", 144): "compact", ("n", 96): "off"}   # ./revit set retina=…
CLONE_MARKER = "revit-macos/smoke-clone"   # in a temporary copy that ./revit test makes
BUILTIN = b"Wine builtin DLL"
# the CrossOver files the fixes copy with another marker (scripts/steps/fixes.sh): source, the copy's marker
SOURCES = {"d3d9": ("lib/dxvk/x86_64-windows/d3d9.dll", b"DXVK native  DLL"),
           "version": ("lib/wine/x86_64-windows/version.dll", b"Wine orig    DLL")}
TOOLS = (("7zz", "sevenzip"), ("winetricks", "winetricks"), ("cabextract", "cabextract"), ("python3", "python3"))
NETFX = {"netfx47": 460798, "netfx48": 528040}   # the Release the step checks for
NETFX_2020_MAX = 461808   # 4.7.2: Revit 2020 crashes on it and on 4.8
WEBVIEW2_MIN = 124        # Revit's WebView2 SDK needs a runtime about this new; the installer's 103 is too old
FREE_MIN_GB = 10
MACOS_TESTED = 26
VERIFIED_BUILD_YEARS = (2025, 2027)   # 2026-10-17: 2025.5 and 2027.3 matched; years whose real Revit.exe matched the installer's build: then a mismatch is a ✗
APP_SCRIPT = re.compile(r"'([^']*/bin/wine)' --bottle '([^']*)'")   # what scripts/make-apps.sh writes
WINEISH = re.compile(r"wine|crossover|\.exe\b", re.I)   # processes that may hold a bottle's files
HOSTS_FIX = "H=\"$(hostname)\"; sudo sh -c \"printf '127.0.0.1\\t$H\\n::1\\t$H\\n' >> /etc/hosts\""
TS = "docs/troubleshooting.md#"
DOC = {"start-over": TS + "start-over", "report": TS + "report-a-problem",
       "rosetta": TS + "revit-does-not-start-from-applications-nothing-happens",
       "hosts": TS + "revit-pauses-for-about-5-seconds",
       "signin": TS + "after-sign-in-the-browser-shows-opening-product-and-nothing-happens",
       "signin-other": TS + "revit-hangs-on-its-loading-window-after-you-sign-in-in-the-browser",
       "web": TS + "start-screen-manage-links-or-project-browser-is-white-a-browser-process-uses-a-lot-of-cpu",
       "netfx2020": TS + "revit-2020-crashes-on-start-after-installing-net-framework-472-or-48"}
# logs/<bottle>/<time>-<kind>[-n] (run_dir_new: a second run of the same second gets -2, -3, ...); older clones wrote
# <time>-<n>-<kind>
LOG_RUN = re.compile(r"^(\d{8}-\d{6})(?:-(\d+))?-([a-z]+)(?:-(\d+))?$")


def run_key(name):
    """(time, n) of a run folder's name, the order run_dir_new made them in, or None for another name."""
    m = LOG_RUN.match(name)
    return (m.group(1), int(m.group(2) or m.group(4) or 1)) if m else None
LOG_LABEL = {"debug": "Revit session", "install": "install", "steps": "steps run", "addins": "add-ins run"}
LOG_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,80}\.log$")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
WHERE = {"system32": "in system32", "revit": "in Revit's folder", "licensing": "in the licensing folder",
         "wbem": "in system32\\wbem", "webview2": "in the WebView2 folder", "rvt-pdf": "in C:\\rvt-pdf",
         "spool": "in the printer drivers folder", "enscape": "in Enscape's folder", "chaos": "in the Chaos folder"}


def rd(year):
    return f"drive_c/Program Files/Autodesk/Revit {year}"


# ---- the fixes: every step_* of scripts/steps/*.sh, what breaks without it (docs/how-it-works.md), and the files a
# check can find in the bottle. A spec: (shim, <shim>, where, path) the file equals $(shim_dir)/<shim>/*.dll|exe;
# (pemark, d3d9|version, where, path) it equals CrossOver's file with our marker; (present, where, path) it is there
# and is not Wine's own; (absent, where, path or glob, name, why) it must not be there; (webview2|netfx|dotnet,).
def _fix(symptom, checks=None, why="no static check yet"):
    return {"symptom": symptom, "checks": checks, "why": why if checks is None else ""}


def _richedit(p, y):
    out = []
    for d in p.get("RICHEDIT") or []:
        out.append(("present", "system32", f"{S32}/{d}.dll"))
        if d != "msftedit":
            out.append(("present", "revit", f"{rd(y)}/{d}.dll"))
    return out + [("absent", "revit", f"{rd(y)}/msftedit.dll", "msftedit.dll",
                   "a second MsftEdit.dll next to Revit.exe fails to load")]


def _enscape(p, y):
    out = [("shim", "vkshim", "system32", f"{S32}/vulkan-1.dll")]
    if str(p.get("ENSCAPE")) == "4":
        out += [("shim", "rvtfix", "enscape", "drive_c/Program Files/Enscape/RendererHost/rvtfix.dll"),
                ("shim", "svcshim", "chaos", "drive_c/Program Files/Chaos/svcshim.exe")]
    return out


VERSION_DLL = ("shim", "wv2fix", "system32", f"{S32}/version.dll")
VERSION_ORIG = ("pemark", "version", "system32", f"{S32}/version_orig.dll")
FIXES = {
    "vc": _fix("part of the install: the Visual C++ runtimes"),
    "fonts": _fix("part of the install: Windows fonts and MSXML"),
    "netfx": _fix("Revit does not start without .NET Framework",
                  lambda p, y: [("netfx",)] if str(p.get("DOTNET", "")).startswith("netfx") else []),
    "dotnet": _fix("Revit does not start without .NET",
                   lambda p, y: [("dotnet",)] if re.match(r"net\d", str(p.get("DOTNET", ""))) else []),
    "licensing": _fix("Autodesk licensing does not work"),
    "svcshim": _fix("the licensing service does not start",
                    lambda p, y: [("shim", "svcshim", "licensing", f"{AL}/svcshim.exe")]),
    "adsso": _fix("the sign-in window does not open"),
    "ssoenv": _fix("the sign-in window loads forever"),
    "idmgr": _fix("sign-in in the Mac's browser does not work"),
    "rcl": _fix("part of the install: Revit's content"),
    "ret": _fix("part of the install: Revit's extensions"),
    "materials": _fix("part of the install: the material library"),
    "samples": _fix("part of the install: sample projects"),
    "rvt": _fix("part of the install: Revit itself"),
    "pkgs": _fix("parts of Revit are missing"),
    "asc": _fix("\"Autodesk Shared Components bundle is missing\" on start"),
    "revitini": _fix("RealDWG does not load (2024, 2025), or there are no templates (2027)"),
    "register": _fix("Revit is not registered with Autodesk licensing"),
    "ncryptshim": _fix("Revit crashes on start and on save",
                       lambda p, y: [("shim", "ncryptshim", "revit", f"{rd(y)}/ncrypt.dll")]),
    "wbemshim": _fix("Revit crashes on New Project and in Options",
                     lambda p, y: [("shim", "wbemshim", "wbem", f"{S32}/wbem/wbemshim.dll")]),
    "webview2": _fix("built-in web pages stay blank", lambda p, y: [("webview2",)]),
    "d3d9dxvk": _fix("panels that draw with Direct3D 9 hang or are unreliable",
                     lambda p, y: [("pemark", "d3d9", "system32", f"{S32}/d3d9.dll"),
                                   ("pemark", "d3d9", "revit", f"{rd(y)}/d3d9.dll")]),
    "richedit": _fix("text in views and dialogs fails", _richedit),
    "tlbpin": _fix("views with text are created 2–3× slower",
                   lambda p, y: [("shim", "tlbpin", "system32", f"{S32}/msls31.dll"),
                                 ("shim", "tlbpin", "revit", f"{rd(y)}/msls31.dll"),
                                 ("present", "system32", f"{S32}/msls31_ms.dll"),
                                 ("present", "revit", f"{rd(y)}/msls31_ms.dll")]),
    "warpshim": _fix("the Materials dialog does not open and its previews crash",
                     lambda p, y: [("shim", "d3dwp", "revit", f"{rd(y)}/d3dwp.dll"), VERSION_DLL, VERSION_ORIG]),
    "gdoff": _fix("a Generative Design error on start"),
    "rvtfix": _fix("the start screen stays blank, and Revit crashes when it opens a view",
                   lambda p, y: [("shim", "rvtfix", "revit", f"{rd(y)}/rvtfix.dll"),
                                 ("shim", "ncryptshim", "revit", f"{rd(y)}/ncrypt.dll"),
                                 ("absent", "revit", f"{rd(y)}/OGSDeviceDX11.dll.orig", "OGSDeviceDX11.dll.orig",
                                  "an older version of this fix changed an Autodesk file on disk"),
                                 ("absent", "revit", f"{rd(y)}/DesktopMFC.dll.orig", "DesktopMFC.dll.orig",
                                  "an older version of this fix changed an Autodesk file on disk")]),
    "wv2fix": _fix("the built-in browser crashes on clicks and resizes",
                   lambda p, y: [VERSION_DLL, VERSION_ORIG,
                                 ("absent", "webview2", f"{WV2}/*/version*.dll", "old-version.dll",
                                  "an older variant of this fix sits next to the browser")]),
    "downloads": _fix("Insert → Load Autodesk Family stops at 100%"),
    "pdfprinter": _fix("without a printer, Print and Page Setup do not open",
                       lambda p, y: [("shim", "pdfprinter", "rvt-pdf", "drive_c/rvt-pdf/add_printer.exe"),
                                     ("present", "spool", f"{S32}/spool/drivers/x64/3/revitpdf.ppd")]),
    "dynamo": _fix("Dynamo's 3D preview draws black squares, lags or crashes"),
    "retina": _fix("text and drawings are blurry on a Retina screen", why="the settings group reads the registry"),
    "mackeys": _fix("Cmd works as Alt: Cmd+S opens a ribbon tab", why="the settings group reads the registry"),
    "revitlookup": _fix("RevitLookup", why="the add-ins checks list it"),
    "pyrevit": _fix("pyRevit", why="the add-ins checks list it"),
    "trust": _fix("Revit asks about signed add-ins on every start"),
    "wpfsw": _fix("black rectangles across Revit after add-ins load"),
    "wpfhw": _fix("software drawing for add-in windows is off again"),
    "check": _fix("a report of the state", why="it changes nothing"),
    "net48": _fix(".NET Framework 4.8 for add-ins"),
    "net472": _fix(".NET Framework 4.7.2 for add-ins"),
    "enscape": _fix("Enscape does not work", _enscape),
    "enscape-off": _fix("Enscape does not load", why="it only moves Enscape's manifest"),
    "enscape-on": _fix("Enscape loads again", why="it only moves Enscape's manifest"),
    "revitmcp": _fix("an AI assistant does not reach Revit (docs/mcp.md)", why="the mcp group checks its files"),
    "revitmcp_experimental": _fix("an AI assistant does not reach Revit (docs/mcp.md)",
                                  why="the mcp group checks its files"),
}


# ---- reading, without writing anything ----
def run(cmd, timeout=20):
    """(exit code, stdout) of a command that only reads; (None, "") when it cannot run. Its children get no fd of
    ours but 0-2 (subprocess closes the rest), stdin is /dev/null."""
    try:
        r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None, ""
    return r.returncode, r.stdout.decode("utf-8", "replace")


def read_bytes(path, limit=64 << 20):
    try:
        with open(path, "rb") as f:
            return f.read(limit)
    except OSError:
        return None


def sha256_of(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def read_plist(path):
    try:
        with open(path, "rb") as f:
            d = plistlib.load(f)
    except Exception:   # a missing, unreadable or broken plist is no plist
        return {}
    return d if isinstance(d, dict) else {}


def grep_bytes(path, pattern):
    data = read_bytes(path)
    m = re.search(pattern, data) if data else None
    return (m.group(1) if m.groups() else m.group(0)).decode("ascii", "replace") if m else None


def pemark_sha(path, new):
    """sha256 of what tools/pe_mark.py makes of a CrossOver file (in memory), or None."""
    data = read_bytes(path, 1 << 30)
    if data is None:
        return None
    i = data.find(BUILTIN)
    if not 0 < i < 0x100:
        return None
    return hashlib.sha256(data[:i] + new + data[i + len(BUILTIN):]).hexdigest()


def reg_values(path, key):
    """{name: (type, value)} of one key of a Wine registry file, None without the file. A bottle's system.reg runs to
    tens of MB: only that key's lines are parsed (bottleread's syntax), not the whole file."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    head = "\n[" + key.lower().replace("\\", "\\\\") + "]"
    i = text.lower().find(head)
    if i < 0:
        return {}
    j = text.find("\n[", i + len(head))
    lines, vals, k = text[i + len(head):j if j >= 0 else len(text)].splitlines()[1:], {}, 0
    while k < len(lines):
        line = lines[k]
        while line.endswith("\\") and k + 1 < len(lines):   # hex lists go on
            k += 1
            line = line[:-1] + lines[k].strip()
        k += 1
        if line.startswith("@="):
            vals["@"] = bottleread._reg_value(line[2:].strip())
            continue
        name, rest = bottleread._split_quoted(line)
        if name is not None and rest is not None:
            vals[bottleread._unescape_reg(name).lower()] = bottleread._reg_value(rest)
    return vals


def show(path, ctx):
    """A path as the output names it: relative to the data folder (as ./revit does), ~, or "an external volume"."""
    if path == ctx.data or path.startswith(ctx.data.rstrip("/") + "/"):
        return os.path.relpath(path, ctx.data)
    if path.startswith("/Volumes/"):
        return "an external volume"
    if path == ctx.home or path.startswith(ctx.home.rstrip("/") + "/"):
        return "~" + path[len(ctx.home.rstrip("/")):]
    return path


def which(tool):
    """Whether a Mac tool is on PATH (Ghostscript also where Homebrew puts it)."""
    return bool(shutil.which(tool)) or (tool == "gs" and os.access("/opt/homebrew/bin/gs", os.X_OK))


class Ctx:
    """What ./revit doctor passes. runner runs a command, which finds a tool, hosts says whether /etc/hosts names this
    Mac: tests give fakes, so they never depend on the Mac they run on."""

    def __init__(self, root, data, cx, bottles, shims=None, lock=None, cx_tested=None, engine=None,
                 shims_release=None, year=None, bottle=None, profile=None, addins=None, home=None, runner=run,
                 which=which, hosts=None):
        self.root, self.data, self.cx, self.bottles = root, data, cx, bottles
        self.shims = shims or os.path.join(root, "build")
        self.lock, self.cx_tested, self.engine, self.shims_release = lock, cx_tested, engine, shims_release
        self.year, self.bottle, self.profile, self.addins = year, bottle, profile or {}, addins or []
        self.home = home or os.environ.get("HOME") or os.path.expanduser("~")
        self.run, self.which, self.hosts = runner, which, hosts or hosts_has_name


def nearest(path):
    """(real path of the nearest folder at or above path that exists, whether path is a link to nothing)"""
    gone = os.path.islink(path) and not os.path.exists(path)
    p = path
    while not os.path.exists(p) and os.path.dirname(p) != p:
        p = os.path.dirname(p)
    return os.path.realpath(p), gone


def free_gb(path, runner):
    """What Finder calls available on the volume of path (purgeable space included), in GB; df's count otherwise."""
    rc, out = runner(["osascript", "-l", "JavaScript", "-e",
                      'function run(a) { ObjC.import("Foundation"); var r = Ref(); '
                      '$.NSURL.fileURLWithPath(a[0]).getResourceValueForKeyError(r, '
                      '$.NSURLVolumeAvailableCapacityForImportantUsageKey, null); '
                      'return Math.floor(ObjC.unwrap(r[0]) / 1e9) }', path])
    if rc == 0 and out.strip().isdigit():
        return int(out.strip())
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    return int(st.f_bavail * st.f_frsize // 1e9)


def downloads(ctx):
    """(label, path) of where an install of the year reads and downloads the installer (revit_downloads)."""
    if ctx.year is None:
        return "installers", os.path.join(ctx.data, "installers")
    inp = os.path.join(ctx.data, "installers", f"revit{ctx.year}")
    if os.path.islink(inp):
        return f"installers/revit{ctx.year}-dl", inp + "-dl"
    return f"installers/revit{ctx.year}", inp


def space(ctx):
    """The volumes of the real paths ./revit writes to (bottles, unpacked files, downloads), each once, and the
    labels of links that point at a volume that is not connected."""
    places = [("bottles", ctx.bottles), ("installers/extracted", os.path.join(ctx.data, "installers", "extracted")),
              downloads(ctx)]
    if ctx.year is not None:
        inp = os.path.join(ctx.data, "installers", f"revit{ctx.year}")
        if os.path.islink(inp):
            places.append((f"installers/revit{ctx.year}", inp))
    try:
        home_dev = os.stat(ctx.home).st_dev
    except OSError:
        home_dev = None
    vols, gone = [], []
    for label, path in places:
        real, lost = nearest(path)
        if lost:
            gone.append(label)
            continue
        try:
            dev = os.stat(real).st_dev
        except OSError:
            continue
        v = next((v for v in vols if v["dev"] == dev), None)
        if v:
            v["labels"].append(label)
            continue
        vols.append({"dev": dev, "labels": [label], "gb": free_gb(real, ctx.run),
                     "volume": "this Mac's disk" if dev == home_dev else "an external volume"})
    return vols, gone


def hosts_has_name(name=None, path="/etc/hosts"):
    """Whether /etc/hosts names this Mac (as install.sh checks); the name itself is never kept."""
    name = name or socket.gethostname()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    return bool(re.search(r"\s" + re.escape(name) + r"(\s|$)", text, re.M))


def lock_state(lock):
    """Whether another task holds the lock (lock_free in scripts/lib/common.sh) and the command it runs. A free lock
    is taken for an instant and dropped; a busy one is only tried."""
    if not lock or not os.path.exists(lock):
        return {"busy": False, "owner": "", "run_id": ""}
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return {"busy": None, "owner": "", "run_id": ""}
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        busy = False
    except OSError:
        busy = True
    finally:
        os.close(fd)
    owner = run_id = ""
    if busy:
        try:
            with open(lock + ".owner", encoding="utf-8", errors="replace") as f:
                lines = f.read(64 << 10).splitlines()
        except OSError:
            lines = []
        owner = next((x[8:] for x in lines if x.startswith("command=")), lines[0] if lines else "")
        run_id = next((x[7:] for x in lines if x.startswith("run_id=")), "")
    return {"busy": busy, "owner": owner or "another task", "run_id": run_id.strip()}


def collect_host(ctx):
    r = ctx.run
    rc, out = r(["sysctl", "-n", "hw.optional.arm64"])
    h = {"arm64": None if rc is None else out.strip() == "1"}
    rc, out = r(["sysctl", "-n", "sysctl.proc_translated"])
    h["translated"] = None if rc is None else out.strip() == "1"
    rc, _ = r(["/usr/bin/arch", "-x86_64", "/usr/bin/true"])
    h["rosetta"] = None if rc is None else rc == 0
    rc, out = r(["sw_vers", "-productVersion"])
    h["macos"] = out.strip() if rc == 0 and out.strip() else None
    h["tools"] = {t: ctx.which(t) for t, _ in TOOLS}
    h["gs"] = ctx.which("gs")
    h["space"], h["gone"] = space(ctx)
    h["hosts"] = ctx.hosts()
    h["lock"] = lock_state(ctx.lock)
    return h


def parts(cx):
    """Versions of CrossOver's parts (JSON only)."""
    p = {}
    v = read_plist(os.path.join(cx, "lib64/apple_gptk/external/D3DMetal.framework/Resources/version.plist"))
    if v.get("CFBundleShortVersionString"):
        p["D3DMetal"] = f"{v['CFBundleShortVersionString']} ({v.get('SourceVersion', '?')})"
    for name, rel, pat in (("DXMT", "lib/dxmt/x86_64-windows/d3d11.dll", rb"v0\.\d+(?:[-.][0-9A-Za-z]+)*"),
                           ("DXVK", "lib/dxvk/x86_64-windows/d3d9.dll", rb"cxaddon-[0-9A-Za-z.\-]+"),
                           ("MoltenVK", "lib64/libMoltenVK.dylib", rb"\x00(1\.\d+\.\d+)\x00"),
                           ("Wine", "lib/wine/x86_64-unix/ntdll.so", rb"wine-\d+\.\d+(?:-[0-9A-Za-z]+)*")):
        s = grep_bytes(os.path.join(cx, rel), pat)
        if s:
            p[name] = s
    mono = sorted(os.path.basename(d) for d in glob.glob(os.path.join(cx, "share/wine/mono/wine-mono-*")))
    if mono:
        p["wine-mono"] = mono[-1]
    return p


def compatdb_sha(home):
    dbs = [d for d in glob.glob(os.path.join(home, "Library/Application Support/CrossOver/compatdb-*.dat"))
           if os.path.isfile(d)]
    return sha256_of(max(dbs, key=os.path.getmtime)) if dbs else None


def collect_cx(ctx):
    cx = ctx.cx
    c = {"found": all(os.access(os.path.join(cx, "bin", x), os.X_OK) for x in ("cxbottle", "wineserver")),
         "tested": ctx.cx_tested}
    pl = read_plist(os.path.join(cx, "..", "..", "Info.plist"))
    c["version"] = str(pl["CFBundleShortVersionString"]) if pl.get("CFBundleShortVersionString") else None
    c["build"] = str(pl["CFBundleVersion"]) if pl.get("CFBundleVersion") else None
    c["markers"] = {k: bottleread.pe_marker(os.path.join(cx, src)) == BUILTIN for k, (src, _) in SOURCES.items()}
    c["pemark"] = {k: pemark_sha(os.path.join(cx, src), new) for k, (src, new) in SOURCES.items()}
    c["parts"] = parts(cx) if c["found"] else {}
    c["compatdb_sha256"] = compatdb_sha(ctx.home)
    return c


def bottle_years(b):
    """The Revit years of a bottle folder: its description and its Revit folders (bottle_years in common.sh)."""
    ys = []
    for keys in bottleread.read_conf(os.path.join(b, "cxbottle.conf")).values():
        m = re.match(r"^Revit (\d{4})$", keys.get("Description", ""))
        if m:
            ys.append(int(m.group(1)))
    for d in glob.glob(os.path.join(b, "drive_c", "Program Files", "Autodesk", "Revit [0-9][0-9][0-9][0-9]")):
        if os.path.isdir(d):
            ys.append(int(d[-4:]))
    return sorted(set(ys))


def clone_state(b):
    """The marker of a temporary copy that ./revit test makes ({state, source, run_id}), or None. As is_smoke_clone
    in scripts/lib/common.sh: the marker a file of its own, neither it nor its folder reached through a link."""
    p = os.path.join(b, CLONE_MARKER)
    if os.path.islink(os.path.dirname(p)) or os.path.islink(p) or not os.path.isfile(p):
        return None
    out = {"state": "unknown", "source": "", "run_id": ""}
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f.read(64 << 10).splitlines():
                k, _, v = line.partition("=")
                if k in out and v.strip():
                    out[k] = v.strip()
    except OSError:
        pass
    return out


def collect_bottles(ctx):
    out = []
    try:
        names = sorted(os.listdir(ctx.bottles))
    except OSError:
        return out
    for name in names:
        p = os.path.join(ctx.bottles, name)
        if os.path.islink(p) or not os.path.isdir(p):
            continue
        clone, ys = clone_state(p), bottle_years(p)
        if clone is None and len(ys) != 1:
            continue   # not a Revit bottle
        if clone is not None:   # whether a running test (or anything else) still uses the copy
            clone["activity"] = activity(p, ctx.run)
        out.append({"name": name, "years": ys, "clone": clone,
                    "revit": len(ys) == 1 and os.path.isfile(os.path.join(p, rd(ys[0]), "Revit.exe"))})
    return out


def activity(bottle, runner):
    """stopped | active | leftover | unknown: whether a Wine process (wineserver, Revit, the licensing services) has the
    bottle folder itself or a file in it open, by real paths as lsof prints them. leftover: such processes, but no
    wineserver among them: what a wineserver that crashed or was killed left behind (they ignore SIGTERM;
    ./revit stop ends them). Never asks Wine."""
    real = os.path.realpath(bottle)
    rc, out = runner(["ps", "-axww", "-o", "pid=,comm=,args="])
    if rc != 0:
        return "unknown"
    mine = {os.getpid(), os.getppid()}
    pids, server = [], set()
    for line in out.splitlines():
        f = line.strip().split(None, 1)
        if len(f) == 2 and f[0].isdigit() and int(f[0]) not in mine and WINEISH.search(f[1]):
            pids.append(f[0])
            if "wineserver" in f[1]:
                server.add(f[0])
    if not pids:
        return "stopped"
    rc, out = runner(["lsof", "-w", "-n", "-P", "-Fn", "-p", ",".join(pids)])
    if rc is None:
        return "unknown"
    pid, holders = None, set()
    for line in out.splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and (line[1:] == real or line[1:].startswith(real.rstrip("/") + "/")):
            holders.add(pid)
    if not holders:
        return "stopped"
    return "active" if holders & server else "leftover"


def documents(b, ctx):
    d = os.path.join(b, DOCUMENTS)
    if os.path.islink(d):
        t = os.readlink(d)
        t = t if os.path.isabs(t) else os.path.normpath(os.path.join(os.path.dirname(d), t))
        return {"kind": "link" if os.path.exists(d) else "dangling", "target": show(t, ctx)}
    return {"kind": "folder" if os.path.isdir(d) else "missing", "target": ""}


def apps(ctx):
    """The apps of the bottle in ~/Applications (scripts/make-apps.sh) and what their scripts start."""
    out = {}
    for key, title in (("revit", f"Revit {ctx.year}"), ("viewer", f"Revit Viewer {ctx.year}"),
                       ("signin", "Autodesk Sign-In")):
        app = os.path.join(ctx.home, "Applications", f"{title} ({ctx.bottle}).app")
        a = {"exists": os.path.isdir(app), "script": None, "bottle": None, "wine": None, "wine_exists": None}
        if a["exists"]:
            rc, src = ctx.run(["osadecompile", os.path.join(app, "Contents", "Resources", "Scripts", "main.scpt")])
            a["script"] = rc == 0 and bool(src.strip())
            m = APP_SCRIPT.search(src) if a["script"] else None
            if m:
                a["wine"], a["bottle"], a["wine_exists"] = m.group(1), m.group(2), os.path.isfile(m.group(1))
        out[key] = a
    others = []   # the Sign-In apps of other bottles: every one of them takes the same adskidmgr:// link
    for app in sorted(glob.glob(os.path.join(ctx.home, "Applications", "Autodesk Sign-In (*).app"))):
        n = os.path.basename(app)[len("Autodesk Sign-In ("):-len(").app")]
        if n != ctx.bottle:
            others.append(n)
    out["signin_others"] = others
    return out


def install_summary(data, name):
    """Steps and failed steps of the newest install log of the bottle (logs/<bottle>/<time>-install), for bottles
    made before the run record."""
    base = os.path.join(data, "logs", name)
    try:
        names = os.listdir(base)
    except OSError:
        names = []
    runs = [os.path.join(base, n) for n in sorted((n for n in names if run_key(n)), key=run_key)
            if LOG_RUN.match(n).group(3) == "install" and os.path.isdir(os.path.join(base, n))]
    if not runs:
        return None
    steps = {}
    for line in runlog._lines(os.path.join(runs[-1], "summary.txt")):
        m = runlog.STEP_LINE.match(line)
        if m and m.group(1) in FIXES:
            steps[m.group(1)] = m.group(2)
    failed = [s.strip() for s in runlog._lines(os.path.join(runs[-1], "failed.txt")) if s.strip()]
    stamp = os.path.basename(runs[-1])
    date = f"{stamp[:4]}-{stamp[4:6]}-{stamp[6:8]}" if re.match(r"^\d{8}-", stamp) else ""
    return {"steps": steps, "failed": failed, "date": date}


def valid_build(b):
    return b if isinstance(b, str) and re.match(r"^\d+(\.\d+){3}$", b) else None


def dist_of(d):
    """The installer root of an unpacked folder (revit_dist_of in versions.sh)."""
    if os.path.isfile(os.path.join(d, "setup.xml")) or os.path.isfile(os.path.join(d, "Setup.ini")):
        return d
    subs = sorted(x for x in glob.glob(os.path.join(d, "*", "")))
    return subs[0].rstrip("/") if subs else d


def expected_build(ctx, records):
    """(the Revit build the installer gives, where that comes from): the newest install record, else the unpacked
    folder's .source (as installer_drift.py wrote it, or worked out again from it)."""
    for r in reversed(records):
        if r.get("kind") == "install" and valid_build(r.get("revit_build_expected")):
            return r["revit_build_expected"], "the install record"
    x = os.path.join(ctx.data, "installers", "extracted", f"revit{ctx.year}")
    src = os.path.join(x, ".source")
    try:
        with open(src, encoding="utf-8") as f:
            s = json.load(f)
    except (OSError, ValueError):
        return None, None
    if isinstance(s, dict) and valid_build(s.get("revit_build_expected")):
        return s["revit_build_expected"], f"installers/extracted/revit{ctx.year}"
    dist = dist_of(x)
    if not os.path.isfile(os.path.join(dist, "setup.xml")):
        return None, None   # Setup.ini (2020) names no build; without the folder nothing is unpacked, nothing written
    import installer_drift
    rd_ = installer_drift.Reader()
    try:
        b = installer_drift.expected_build(installer_drift.load_source(src), dist, rd_)
    except Exception:   # a source list it cannot read gives no build, never a crash
        b = None
    finally:
        rd_.close()
    return (b, f"installers/extracted/revit{ctx.year}") if valid_build(b) else (None, None)


def specs(profile, year, steps):
    """[(step, spec)] of the given steps, in order."""
    out = []
    for s in steps:
        fn = (FIXES.get(s) or {}).get("checks")
        for sp in (fn(profile, year) if fn else []):
            out.append((s, sp))
    return out


def file_info(path):
    if not os.path.isfile(path):
        return {"exists": False, "sha256": None, "marker": None}
    m = bottleread.pe_marker(path)
    return {"exists": True, "sha256": sha256_of(path), "marker": m.decode("ascii") if m else None}


def shim_info(ctx, shim):
    """This project's current file of a shim ($(shim_dir)/<shim>/*.dll|exe), and whether its sources are newer than
    the built file (a clone that builds from source: then the bottle cannot be compared with it)."""
    files = sorted(glob.glob(os.path.join(ctx.shims, shim, "*.dll")) +
                   glob.glob(os.path.join(ctx.shims, shim, "*.exe")))
    if not files:
        return {"file": None, "sha256": None, "stale": False}
    built, stale = files[0], False
    release = os.path.isfile(os.path.join(ctx.shims, ".prebuilt")) or \
        os.path.isfile(os.path.join(ctx.root, ".app-bundle"))
    if not release and os.path.realpath(ctx.shims) == os.path.realpath(os.path.join(ctx.root, "build")):
        dirs = (os.path.join(ctx.root, "tools", "shims", shim), os.path.join(ctx.root, "tools", "shims", "common"))
        srcs = [p for d in dirs for p in glob.glob(os.path.join(d, "**", "*"), recursive=True) if os.path.isfile(p)]
        srcs.append(os.path.join(ctx.root, "scripts", "build-shims.sh"))
        try:
            t = os.path.getmtime(built)
            stale = any(os.path.isfile(p) and os.path.getmtime(p) > t for p in srcs)
        except OSError:
            stale = False
    return {"file": os.path.relpath(built, ctx.shims), "sha256": sha256_of(built), "stale": stale}


def install_times(records):
    """(when the newest install ended, when it began) as epoch seconds, or (None, None). The record is written at its
    end; its run id begins with the local time ./revit started it (else: three hours before the end)."""
    last = next((r for r in reversed(records or []) if r.get("kind") == "install"), None)
    if not last:
        return None, None
    try:
        end = calendar.timegm(time.strptime(str(last.get("time")), "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, OverflowError):
        end = None
    m = re.match(r"^(\d{8}-\d{6})", str(last.get("run_id") or ""))
    try:
        begin = time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S")) if m else None
    except (ValueError, OverflowError):
        begin = None
    if begin is None and end is not None:
        begin = end - 3 * 3600
    return end, begin


def run_time(path):
    """When a run folder began: the local time in its name, else its modification time."""
    m = LOG_RUN.match(os.path.basename(path))
    try:
        return time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S")) if m else os.path.getmtime(path)
    except (ValueError, OverflowError, OSError):
        return None


def collect_logs(ctx, bottle_dir, records):
    """The newest logs of the bottle, each scanned once for the signatures of tools/signatures.py: the newest debug
    session, the newest install, steps or add-ins run, Revit's newest journal. A log older than the last install is
    not read: it is about the bottle before it was installed again."""
    end, begin = install_times(records)
    out = {"sources": [], "skipped": []}
    base = os.path.join(ctx.data, "logs", ctx.bottle)
    newest = {}
    try:
        names = os.listdir(base)
    except OSError:
        names = []
    for n in names:
        m, d = LOG_RUN.match(n), os.path.join(base, n)
        if m and m.group(3) in LOG_LABEL and os.path.isdir(d) and not os.path.islink(d):
            key = run_key(n)
            if m.group(3) not in newest or key > newest[m.group(3)][0]:
                newest[m.group(3)] = (key, d)

    def regular(p):
        return os.path.isfile(p) and not os.path.islink(p)

    def scan(label, path, t, shown):
        res = signatures.scan_file(path, year=ctx.year)
        if res["where"]:
            out["sources"].append({"label": label, "file": shown, "time": t, "scan": res})
    if "debug" in newest:
        d = newest["debug"][1]
        t = run_time(d)
        if end is not None and t is not None and t < end:
            out["skipped"].append({"label": LOG_LABEL["debug"], "time": t})
        else:
            for n in ("wine.cxlog", "stdout.log"):
                if regular(os.path.join(d, n)):
                    scan(LOG_LABEL["debug"], os.path.join(d, n), t, show(os.path.join(d, n), ctx))
    runs = [newest[k] for k in ("install", "steps", "addins") if k in newest]
    if runs:
        d = max(runs)[1]
        kind, t = LOG_RUN.match(os.path.basename(d)).group(3), run_time(d)
        if begin is not None and t is not None and t < begin:
            out["skipped"].append({"label": LOG_LABEL[kind], "time": t})
        else:
            try:
                names = sorted(os.listdir(d))
            except OSError:
                names = []
            for n in names:
                if LOG_NAME.match(n) and regular(os.path.join(d, n)):
                    scan(LOG_LABEL[kind], os.path.join(d, n), t, show(os.path.join(d, n), ctx))
    j = bottleread.newest_journal(bottle_dir, ctx.year)
    try:   # Revit deletes old journals as it starts: this one can be gone already
        t = os.path.getmtime(j) if j and regular(j) else None
    except OSError:
        t = None
    if t is not None:
        if end is not None and t < end:
            out["skipped"].append({"label": "Revit journal", "time": t})
        else:
            scan(LOG_LABEL["debug"], j, t, "Journals/" + os.path.basename(j))
    return out


# Autodesk's Revit MCP Server (scripts/lib/mcp.sh holds the same table): id, folder under Program Files\Autodesk, label
MCP_VARIANTS = (("revitmcp", "Revit {y} MCP Server Write-Tools Technical Preview", "Write-Tools"),
                ("revitmcp-experimental", "Revit {y} MCP Server Experimental-Tools Technical Preview",
                 "Experimental-Tools"))
MCP_MANIFEST = "drive_c/Program Files/Autodesk/Revit/Addins/{y}/Autodesk.RevitMcpServer.addin"
MCP_ADP_MARKER = "drive_c/ProgramData/revit-macos/adp"
MCP_ADP_CORE = "drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin/AdpSDKCore.dll"
MCP_EXPIRES = "2028-05-01"   # the Technical Preview stops working then
# pyRevit's agent (./revit mcp --server pyrevit; scripts/lib/mcp.sh holds the same paths and ini rules)
PYREVIT_CLONE_REL = "drive_c/users/crossover/AppData/Roaming/pyRevit-Master"
PYREVIT_CONFIG_REL = "drive_c/users/crossover/AppData/Roaming/pyRevit/pyRevit_config.ini"


def collect_mcp(ctx, p):
    """The MCP Server's files in bottle p: the manifest's variant (None: no manifest; "": one we do not know), each
    variant folder that exists, our launcher next to it against this project's shims, the ADP marker and DLL."""
    y, j = ctx.year, os.path.join
    m = {"manifest": None, "folders": {}, "today": time.strftime("%Y-%m-%d"),
         "shims": {s: shim_info(ctx, s) for s in ("mcphost", "mcppipes")}}
    try:
        with open(j(p, MCP_MANIFEST.format(y=y)), encoding="utf-8-sig", errors="replace") as fh:
            a = re.search(r"<Assembly>(.*)\\[^\\]*</Assembly>", fh.read())
        m["manifest"] = next((i for i, d, _ in MCP_VARIANTS if a and a.group(1).strip() ==
                              "C:\\Program Files\\Autodesk\\" + d.format(y=y)), "")
    except OSError:
        pass
    for i, d, _ in MCP_VARIANTS:
        fd = j(p, "drive_c/Program Files/Autodesk", d.format(y=y))
        if os.path.isdir(fd):
            m["folders"][i] = {"stdio": os.path.isfile(j(fd, "Autodesk.RevitMcpServer.Stdio.exe")),
                               "mcphost": file_info(j(fd, "mcphost.exe"))["sha256"],
                               "mcppipes": file_info(j(fd, "mcppipes.dll"))["sha256"]}
    try:
        with open(j(p, MCP_ADP_MARKER), encoding="utf-8", errors="replace") as fh:
            m["adp_marker"] = fh.read().strip()
    except OSError:
        m["adp_marker"] = None
    m["adp_core"] = os.path.isfile(j(p, MCP_ADP_CORE))
    return m


def collect_bottle(ctx):
    y, p = ctx.year, os.path.join(ctx.bottles, ctx.bottle)
    b = {"link": os.path.islink(p)}
    b["exists"] = os.path.isdir(p) and not b["link"]
    if not b["exists"]:
        return b
    b["clone"], b["years"] = clone_state(p), bottle_years(p)
    if b["clone"] is not None:
        b["clone"]["activity"] = activity(p, ctx.run)
    if b["clone"] is not None or b["years"] != [y]:
        return b
    b["registry"] = {n: os.path.isfile(os.path.join(p, n)) for n in ("system.reg", "user.reg")}
    exe = os.path.join(p, rd(y), "Revit.exe")
    b["revit_exe"] = os.path.isfile(exe)
    b["revit_version"] = bottleread.pe_file_version(exe) if b["revit_exe"] else None
    b["documents"] = documents(p, ctx)
    b["apps"] = apps(ctx)
    b["activity"] = activity(p, ctx.run)
    b["records"] = runlog.records(p)
    b["summary"] = install_summary(ctx.data, ctx.bottle)
    b["expected"], b["expected_from"] = expected_build(ctx, b["records"])
    b["files"], b["globs"], b["shims"] = {}, {}, {}
    for _, sp in specs(ctx.profile, y, list(FIXES)):
        if sp[0] in ("shim", "pemark", "present"):
            rel = spec_place(sp)[1]
            b["files"][rel] = file_info(os.path.join(p, rel))
        if sp[0] == "shim" and sp[1] not in b["shims"]:
            b["shims"][sp[1]] = shim_info(ctx, sp[1])
        if sp[0] == "absent":
            b["globs"][sp[2]] = sorted(os.path.relpath(x, p) for x in glob.glob(os.path.join(p, sp[2])))
    wv = os.path.join(p, WV2)
    b["webview2"] = sorted((v for v in (os.listdir(wv) if os.path.isdir(wv) else []) if re.match(r"^\d+(\.\d+)+$", v)
                            and os.path.isfile(os.path.join(wv, v, "msedgewebview2.exe"))),
                           key=lambda v: [int(x) for x in v.split(".")])
    dd = os.path.join(p, DESKTOP)
    b["desktop"] = sorted(v for v in (os.listdir(dd) if os.path.isdir(dd) else []) if re.match(r"^\d+\.", v))
    netfx = {"clr": os.path.isfile(os.path.join(p, NETFX_DIR, "clr.dll")), "release": None, "reg": None}
    if str(ctx.profile.get("DOTNET", "")).startswith("netfx"):
        vals = reg_values(os.path.join(p, "system.reg"), NDP_KEY)
        netfx["reg"] = vals is not None
        rel = (vals or {}).get("release")
        netfx["release"] = rel[1] if rel and rel[0] == "dword" else None
    b["netfx"] = netfx
    b["logs"] = collect_logs(ctx, p, b["records"])
    b["mcp"] = collect_mcp(ctx, p)
    b["pyrevit_agent"] = collect_pyrevit_agent(p)
    if any(s in (ctx.profile.get("STEPS") or []) for s in SETTING_STEPS):
        b["settings"] = collect_settings(p)
    return b


def collect_settings(p):
    """The registry values the steps retina and mackeys write, as reg_values gives them; None: no such file."""
    user, system = os.path.join(p, "user.reg"), os.path.join(p, "system.reg")
    return {"mac": reg_values(user, MAC_DRIVER), "app": reg_values(user, MAC_DRIVER_APP),
            "hkcu": reg_values(user, DESKTOP_KEY), "hklm": reg_values(system, FONTS_HKLM)}


def collect(ctx):
    """Every fact the checks need; the only function here that reads the Mac and the bottle."""
    f = {"year": ctx.year, "bottle": ctx.bottle, "profile": ctx.profile, "addins": ctx.addins,
         "engine": ctx.engine or "unknown", "shims_release": ctx.shims_release or "unknown",
         "bottles_path": ctx.bottles, "home": ctx.home, "cx_path": ctx.cx}
    f["sfx"] = "" if ctx.year is None or ctx.bottle == f"rvt{ctx.year}-a" else f" {ctx.bottle}"
    f["host"] = collect_host(ctx)
    f["cx"] = collect_cx(ctx)
    if ctx.year is None:
        f["bottles"] = collect_bottles(ctx)
    else:
        f["b"] = collect_bottle(ctx)
    return f


# ---- the checks: from facts only ----
class Check:
    """One line of the result. show=False: an info line for the JSON only."""

    def __init__(self, id_, status, title, detail="", fix="", doc="", show=True):
        self.id, self.group, self.status = id_, id_.split(".", 1)[0], status
        self.title, self.detail, self.fix, self.doc, self.show = title, detail, fix, doc, show

    def json(self):
        return {"id": self.id, "group": self.group, "status": self.status, "title": self.title,
                "detail": self.detail, "fix": self.fix, "doc": self.doc}


def rebuild(f):
    return f"./revit rebuild {f['year']}{f['sfx']}: it shows what it resets and asks first"


def clone_check(f, cid, name, years, clone):
    """What doctor says of a temporary copy that ./revit test made. A copy a running ./revit test owns (the lock's
    run id is the marker's; an owner file without one: its command names the copy's source), or one where programs
    run, is in use: a note, no command. A kept one (--keep) gets the maintainer's command that ./revit test prints. Any
    other is left behind: ./revit test removes it, with its own checks, the next time it runs; never a bare delete."""
    src, state = clone.get("source") or "", clone.get("state")
    of = f" of {src}" if src else ""
    lk = f["host"].get("lock") or {}
    words = (lk.get("owner") or "").split()
    owned = bool(lk.get("busy")) and state in ("creating", "ready") and (
        lk.get("run_id") == clone.get("run_id") if lk.get("run_id") else
        bool(src) and words[:2] == ["./revit", "test"] and words[3:4] == [src])
    if not name.endswith(".test"):
        return Check(cid, "warn", f"{name} holds the marker of a temporary copy that ./revit test makes, but is not "
                     "named like one: ./revit test leaves it alone",
                     detail=f"state {state or 'unknown'}",
                     fix="if it is your own bottle, delete the file revit-macos/smoke-clone in it; if it is a copy, "
                         "delete it in CrossOver")
    if owned or clone.get("activity") in ("active", "leftover"):
        return Check(cid, "info", f"{name}: a temporary copy{of}, in use by ./revit test",
                     detail=f"state {state or 'unknown'}, " + ("the running ./revit test owns it" if owned else
                                                               "programs run in it"))
    if state == "kept":
        home, cx = f["home"].rstrip("/"), f.get("cx_path") or ""
        if cx.startswith(home + "/"):
            cx = "$HOME" + cx[len(home):]
        return Check(cid, "warn", f"a temporary copy{of} that ./revit test kept (--keep): {name}",
                     detail="state kept", fix=f'when you no longer need it: "{cx}/bin/cxbottle" --bottle "{name}" '
                                              "--delete --force")
    y = years[0] if len(years) == 1 else None
    again = "./revit test " + (f"{y}" + ("" if not src or src == f"rvt{y}-a" else f" {src}") if y else "<year>")
    return Check(cid, "warn", f"a temporary copy{of} that ./revit test made was left behind: {name}",
                 detail=f"state {state or 'unknown'}", fix=f"run {again} again: it removes copies left behind")


def host_checks(f):
    h, out = f["host"], []
    if h.get("arm64") is False:
        out.append(Check("host.arm64", "fail", "Apple Silicon Mac required",
                         fix="this setup is tested on M-series Macs only"))
    elif h.get("arm64"):
        out.append(Check("host.arm64", "ok", "an Apple Silicon Mac"))
    if h.get("translated"):
        out.append(Check("host.terminal", "fail", "this Terminal runs under Rosetta",
                         fix="quit Terminal, turn off \"Open using Rosetta\" in its Get Info window, and run again"))
    elif h.get("translated") is False:
        out.append(Check("host.terminal", "ok", "this Terminal does not run under Rosetta"))
    if h.get("rosetta") is False:
        out.append(Check("host.rosetta", "fail", "Rosetta 2 is not installed: the Revit app fails without a message",
                         fix="softwareupdate --install-rosetta --agree-to-license", doc=DOC["rosetta"]))
    elif h.get("rosetta"):
        out.append(Check("host.rosetta", "ok", "Rosetta 2 is installed"))
    v = h.get("macos")
    if v:
        major = int(v.split(".")[0]) if v.split(".")[0].isdigit() else MACOS_TESTED
        if major < MACOS_TESTED:
            out.append(Check("host.macos", "warn",
                             f"macOS {v} is older than macOS {MACOS_TESTED}, which this setup is tested on",
                             fix="update macOS; on this one, report what works and what does not", doc=DOC["report"]))
        else:
            out.append(Check("host.macos", "ok", f"macOS {v}"))
    for t, pkg in TOOLS:
        if t in h.get("tools", {}):
            out.append(Check(f"host.tool.{t}", "ok", f"{t} found") if h["tools"][t] else
                       Check(f"host.tool.{t}", "warn", f"{t} not found: ./revit install and rebuild need it",
                             fix=f"brew install {pkg}"))
    for label in h.get("gone", []):
        out.append(Check(f"host.space.{label.replace('/', '-')}", "warn",
                         f"{label} points to a volume that is not connected",
                         fix="connect that disk before ./revit install, rebuild or remove"))
    for v in h.get("space", []):
        where, cid = f"{v['volume']} ({', '.join(v['labels'])})", f"host.space.{v['labels'][0].replace('/', '-')}"
        if v.get("gb") is None:
            out.append(Check(cid, "info", f"free space on {where} could not be read", show=False))
        elif v["gb"] < FREE_MIN_GB:
            out.append(Check(cid, "warn", f"only {v['gb']} GB free on {where}",
                             fix="free some space: Revit needs room to work, and ./revit rebuild needs up to 45 GB "
                                 "(installers/README.md lists the sizes)"))
        else:
            out.append(Check(cid, "ok", f"{v['gb']} GB free on {where}"))
    if h.get("hosts") is False:
        out.append(Check("host.hosts", "warn",
                         "this Mac's name is not in /etc/hosts: Revit waits about 5 s on every lookup of it",
                         fix=HOSTS_FIX, doc=DOC["hosts"]))
    elif h.get("hosts"):
        out.append(Check("host.hosts", "ok", "this Mac's name is in /etc/hosts"))
    lk = h.get("lock") or {}
    if lk.get("busy"):
        out.append(Check("host.lock", "info", f"another task is running: {lk.get('owner') or 'another task'}",
                         detail="./revit doctor does not wait for it; what it reads may change meanwhile"))
    elif lk.get("busy") is False:
        out.append(Check("host.lock", "ok", "no other task is running"))
    return out


def crossover_checks(f):
    c, out = f["cx"], []
    if not c.get("found"):
        return [Check("crossover.found", "fail", "CrossOver not found in /Applications",
                      fix="install it from https://www.codeweavers.com/crossover (trial available)")]
    name = f"CrossOver {c.get('version') or ''}".rstrip()
    out.append(Check("crossover.found", "ok", f"{name} found"))
    if not c.get("build"):
        out.append(Check("crossover.version", "info", "CrossOver's version could not be read", show=False))
    elif c.get("tested") and c["build"] != c["tested"]:
        out.append(Check("crossover.version", "warn",
                         f"{name} ({c['build']}) is not the version this setup is tested on ({c['tested']})",
                         fix="it may work; if Revit misbehaves, report a problem", doc=DOC["report"]))
    else:
        out.append(Check("crossover.version", "ok", f"{name} is the version this setup is tested on"))
    gone = [SOURCES[k][0].split("/")[-1] + " (" + SOURCES[k][0].split("/")[1] + ")"
            for k, ok in sorted((c.get("markers") or {}).items()) if not ok]
    if gone:
        out.append(Check("crossover.files", "warn",
                         f"CrossOver lacks files the fixes copy, or they changed: {', '.join(gone)}",
                         detail="the Direct3D 9 and browser fixes are made from them at install",
                         fix="reinstall CrossOver; if this CrossOver is new, report a problem", doc=DOC["report"]))
    elif c.get("markers"):
        out.append(Check("crossover.files", "ok", "CrossOver has the files the fixes copy"))
    if c.get("parts"):
        out.append(Check("crossover.parts", "info", "CrossOver's parts: " +
                         ", ".join(f"{k} {v}" for k, v in sorted(c["parts"].items())),
                         detail=json.dumps(c["parts"], sort_keys=True), show=False))
    if c.get("compatdb_sha256"):
        out.append(Check("crossover.compatdb", "info",
                         f"CrossOver's compatibility database: sha256 {c['compatdb_sha256']}", show=False))
    return out


def bottles_checks(f):
    out, revits = [], 0
    for b in f.get("bottles", []):
        if b["clone"] is not None:
            out.append(clone_check(f, f"bottles.clone.{b['name']}", b["name"], b["years"], b["clone"]))
            continue
        revits += 1
        y = b["years"][0]
        sfx = "" if b["name"] == f"rvt{y}-a" else " " + b["name"]
        out.append(Check(f"bottles.{b['name']}", "info",
                         f"{b['name']}: Revit {y}" + ("" if b["revit"] else ", Revit is not installed in it"),
                         fix="" if b["revit"] else f"./revit doctor {y}{sfx} says more"))
    if not revits:
        out.append(Check("bottles.none", "info", "no Revit bottles yet", fix="to install one: ./revit install <year>"))
    return out


def app_checks(f, b):
    y, name, out = f["year"], f["bottle"], []
    fix = f"scripts/make-apps.sh {y} {name} makes it again"
    for key, title in (("revit", f"the Revit {y} app"), ("signin", f"Autodesk Sign-In ({name})")):
        if key == "signin" and f["profile"].get("SIGNIN") != "idmgr":
            continue
        a, cid = b["apps"].get(key) or {}, f"bottle.app.{key}"
        doc = DOC["signin"] if key == "signin" else ""
        why = ": after sign-in the browser shows \"Opening product\" and nothing happens" if key == "signin" else ""
        if not a.get("exists"):
            out.append(Check(cid, "warn", f"{title} is missing in ~/Applications{why}", fix=fix, doc=doc))
        elif not a.get("script"):
            out.append(Check(cid, "info", f"what {title} starts could not be read", show=False))
        elif a.get("bottle") is None:
            out.append(Check(cid, "warn", f"{title} does not start Revit through CrossOver{why}", fix=fix, doc=doc))
        elif a["bottle"] != name:
            out.append(Check(cid, "warn", f"{title} starts another bottle ({a['bottle']}){why}", fix=fix, doc=doc))
        elif not a.get("wine_exists"):
            out.append(Check(cid, "warn", f"{title} starts CrossOver from where it is no longer{why}", fix=fix,
                             doc=doc))
        else:
            out.append(Check(cid, "ok", f"{title} starts this bottle"))
    others = b["apps"].get("signin_others") or []
    if f["profile"].get("SIGNIN") == "idmgr" and others:
        out.append(Check("bottle.app.signin-others", "info",
                         f"other bottles take the sign-in link too ({', '.join(others[:4])}): when the browser asks "
                         f"after you sign in, choose Autodesk Sign-In ({name}), or Revit hangs on its loading window",
                         doc=DOC["signin-other"]))
    if y >= 2027 and (b["apps"].get("viewer") or {}).get("exists"):
        out.append(Check("bottle.app.viewer", "info", f"there is a Revit Viewer {y} app; Revit {y} has no Viewer mode",
                         show=False))
    return out


def ran_steps(b):
    """The steps the bottle has seen: done, skipped or failed in the newest install record and the records after it;
    without an install record (a bottle made before the run record), the steps of the newest install log and of every
    record. None when neither tells how the bottle was installed: a steps or add-ins run alone does not."""
    recs = b.get("records") or []
    last = max((i for i, r in enumerate(recs) if r.get("kind") == "install"), default=None)
    if last is None and not b.get("summary"):
        return None
    seen = set() if last is not None else set(b["summary"]["steps"])
    for r in recs[last or 0:]:
        for k in ("done", "skipped", "failed"):
            seen.update(x for x in r.get(k) or [] if isinstance(x, str))
    return seen


def engine_key(e):
    """git:abc+dirty → git:abc; unknown → None."""
    e = str(e or "unknown")
    return None if e == "unknown" else e.split("+", 1)[0]


def install_checks(f, b):
    out, y = [], f["year"]
    recs = b.get("records") or []
    installs = [r for r in recs if r.get("kind") == "install"]
    last = installs[-1] if installs else None
    if last:
        date = str(last.get("time", ""))[:10]
        later = recs[recs.index(last) + 1:]
        fixed = {s for r in later for s in r.get("done") or []}
        left = [s for s in last.get("failed") or [] if s not in fixed and s not in SETTING_STEPS]
        res = last.get("result")
        if res == "ok" or (res == "partial" and not left):
            out.append(Check("install.last", "ok", f"the last install ({date}) finished"))
        elif res == "partial":
            out.append(Check("install.last", "warn", f"the last install ({date}) left fixes undone: " +
                             "; ".join(FIXES.get(s, {}).get("symptom", s) for s in left),
                             detail="steps: " + " ".join(left), fix=rebuild(f), doc=DOC["start-over"]))
        elif res == "stopped":
            out.append(Check("install.last", "warn", f"the last install ({date}) was stopped before it finished",
                             fix=rebuild(f), doc=DOC["start-over"]))
        else:
            at = f" at {' '.join(left)}" if left else ""
            out.append(Check("install.last", "warn", f"the last install ({date}) failed",
                             detail=f"failed{at}" if at else "", fix=rebuild(f), doc=DOC["start-over"]))
    elif b.get("summary"):
        s = b["summary"]
        sf = [x for x in s["failed"] if x not in SETTING_STEPS]   # settings: the settings group says what to do
        if sf:
            out.append(Check("install.last", "warn", f"the last install ({s['date']}) left fixes undone: " +
                             "; ".join(FIXES.get(x, {}).get("symptom", x) for x in sf),
                             detail="steps: " + " ".join(sf), fix=rebuild(f), doc=DOC["start-over"]))
        else:
            out.append(Check("install.last", "ok", f"the last install ({s['date']}) finished",
                             detail="from its log: the bottle has no run record"))
    else:
        out.append(Check("install.last", "info", "no record of how this bottle was installed",
                         detail="made before this project kept a run record, and its install log is gone", show=False))
    ran = ran_steps(b)
    steps = [s for s in f["profile"].get("STEPS") or []]
    if ran is not None:
        miss = [s for s in steps if s not in ran and s not in SETTING_STEPS]
        if miss:
            out.append(Check("install.steps", "warn", f"this bottle lacks fixes this project has now ({len(miss)}): " +
                             "; ".join(FIXES.get(s, {}).get("symptom", s) for s in miss),
                             detail="steps: " + " ".join(miss), fix=rebuild(f), doc=DOC["start-over"]))
        else:
            out.append(Check("install.steps", "ok", f"this bottle has every fix of Revit {y}'s profile"))
    if last:
        old = (engine_key(last.get("engine")), engine_key(last.get("shims")))
        now = (engine_key(f.get("engine")), engine_key(f.get("shims_release")))
        if any(o and n and o != n for o, n in zip(old, now)):
            out.append(Check("install.engine", "info",
                             "installed by an older version of this project; new fixes reach it after a rebuild",
                             detail=f"then {last.get('engine')}, shims {last.get('shims')}; now {f.get('engine')}, "
                                    f"shims {f.get('shims_release')}",
                             fix="when you want them: " + rebuild(f)))
    have, want = b.get("revit_version"), b.get("expected")
    if have and want:
        same = [int(x) for x in have.split(".")] == [int(x) for x in want.split(".")]
        if same:
            out.append(Check("install.build", "ok", f"Revit.exe is build {have}, as the installer gives"))
        else:
            out.append(Check("install.build", "fail" if y in VERIFIED_BUILD_YEARS else "warn",
                             f"Revit.exe is build {have}, the installer gives {want}",
                             detail=f"from {b.get('expected_from')}; Revit.exe's FileVersion" +
                                    ("" if y in VERIFIED_BUILD_YEARS else
                                     " (not yet compared on a real bottle of this year)"),
                             fix=f"if you unpacked a newer update since: {rebuild(f)}"))
    elif have:
        out.append(Check("install.build", "info", f"Revit.exe is build {have}; the installer's build is not known",
                         show=False))
    return out


def since_install(f, b):
    """CrossOver now against the one the newest install record names."""
    last = next((r for r in reversed(b.get("records") or []) if r.get("kind") == "install"), None)
    then, now = (last or {}).get("crossover"), f["cx"].get("build")
    if not (then and now):
        return []
    if then == now:
        return [Check("crossover.since-install", "ok", f"CrossOver is the one Revit {f['year']} was installed with")]
    return [Check("crossover.since-install", "warn",
                  f"CrossOver changed since Revit {f['year']} was installed: {then} then, {now} now",
                  detail="the Direct3D 9 and browser fixes are made from CrossOver's own files at install",
                  fix=f"if Revit misbehaves: {rebuild(f)}", doc=DOC["start-over"])]


def spec_place(sp):
    """(where, path) of a file spec."""
    return (sp[2], sp[3]) if sp[0] in ("shim", "pemark") else (sp[1], sp[2])


def file_check(f, b, step, sp):
    """The check of one file spec."""
    kind, (where, rel) = sp[0], spec_place(sp)
    symptom = FIXES[step]["symptom"]
    loc = WHERE.get(where, "")
    if kind == "absent":
        name, why = sp[3], sp[4]
        cid = f"fixes.{step}.{where}.{name}"
        found = b["globs"].get(rel) or []
        if found:
            return Check(cid, "warn", f"{os.path.basename(found[0])} {loc} should not be there: {why}",
                         detail=" ".join(found), fix=rebuild(f), doc=DOC["start-over"])
        return Check(cid, "ok", f"no {name} {loc}")
    name = os.path.basename(rel)
    cid = f"fixes.{step}.{where}.{name}"
    fi = b["files"].get(rel) or {"exists": False}
    if not fi.get("exists"):
        return Check(cid, "fail", f"{name} {loc} is missing; without it {symptom}", detail=f"step {step}",
                     fix=rebuild(f), doc=DOC["start-over"])
    if fi.get("marker") == BUILTIN.decode():   # Wine's own stub: the fix never got there, or was replaced
        return Check(cid, "fail", f"{name} {loc} is Wine's own, not the fix; without the fix {symptom}",
                     detail=f"step {step}", fix=rebuild(f), doc=DOC["start-over"])
    if kind == "present":
        return Check(cid, "ok", f"{name} {loc} is in place")
    if kind == "shim":
        si = b["shims"].get(sp[1]) or {}
        if not si.get("sha256"):
            return Check(cid, "info", f"{name} {loc}: not compared, this project has no build of it here",
                         detail=f"shim {sp[1]}", show=False)
        if si.get("stale"):
            return Check(cid, "info", f"{name} {loc}: not compared, tools/shims/{sp[1]} changed after it was built",
                         detail=f"build/{sp[1]}/{si.get('file')} is older than its sources", show=False)
        if fi.get("sha256") == si["sha256"]:
            return Check(cid, "ok", f"{name} {loc} is this project's current fix")
        return Check(cid, "warn", f"{name} {loc} is not this project's current fix; it fixes: {symptom}",
                     detail=f"shim {sp[1]}: {fi.get('sha256')} in the bottle, {si['sha256']} here",
                     fix=rebuild(f), doc=DOC["start-over"])
    want = (f["cx"].get("pemark") or {}).get(sp[1])   # pemark
    if not want:
        return Check(cid, "info", f"{name} {loc}: not compared, CrossOver's own file could not be read", show=False)
    if fi.get("sha256") == want:
        return Check(cid, "ok", f"{name} {loc} is made from this CrossOver")
    ours = fi.get("marker") == SOURCES[sp[1]][1].decode()
    return Check(cid, "warn", (f"{name} {loc} was made from another CrossOver" if ours else
                               f"{name} {loc} is not this project's fix") + f"; it fixes: {symptom}",
                 detail=f"{fi.get('sha256')} in the bottle, {want} from this CrossOver",
                 fix=rebuild(f), doc=DOC["start-over"])


def runtime_check(f, b, step, kind):
    y, p = f["year"], f["profile"]
    if kind == "webview2":
        vs = b.get("webview2") or []
        if not vs:
            return Check("fixes.webview2", "fail",
                         "the WebView2 browser runtime is not in the bottle: built-in web pages stay blank",
                         fix=rebuild(f), doc=DOC["web"])
        v = vs[-1]
        if int(v.split(".")[0]) < WEBVIEW2_MIN:
            return Check("fixes.webview2", "fail", f"the WebView2 browser runtime in the bottle is too old ({v}): "
                         "built-in web pages stay blank", detail=" ".join(vs), fix=rebuild(f), doc=DOC["web"])
        return Check("fixes.webview2", "ok", f"WebView2 browser runtime {v}", detail=" ".join(vs))
    if kind == "dotnet":
        major = re.sub(r"\D", "", str(p.get("DOTNET", "")))
        have = b.get("desktop") or []
        if any(v.split(".")[0] == major for v in have):
            return Check("fixes.dotnet", "ok", f".NET {major} is in the bottle", detail=" ".join(have))
        return Check("fixes.dotnet", "fail", f".NET {major} is not in the bottle: Revit does not start",
                     detail=" ".join(have), fix=rebuild(f), doc=DOC["start-over"])
    nf = b.get("netfx") or {}   # netfx
    if not nf.get("clr"):
        return Check("fixes.netfx", "fail", ".NET Framework is not in the bottle: Revit does not start",
                     fix=rebuild(f), doc=DOC["start-over"])
    rel, need = nf.get("release"), NETFX.get(str(p.get("DOTNET")), 0)
    if rel is None:
        if b.get("activity") in ("active", "leftover"):
            return Check("fixes.netfx", "info", ".NET Framework's version: not visible (bottle active)",
                         detail="Wine writes the registry to disk up to about 30 s late while the bottle runs")
        if nf.get("reg"):
            return Check("fixes.netfx", "warn",
                         ".NET Framework's version is not in the registry: its install may be incomplete",
                         fix=rebuild(f), doc=DOC["start-over"])
        return Check("fixes.netfx", "ok", ".NET Framework is in the bottle",
                     detail="its version not read: no system.reg")
    if rel < need:
        return Check("fixes.netfx", "fail",
                     f".NET Framework in the bottle is too old (Release {rel}): Revit does not start",
                     fix=rebuild(f), doc=DOC["start-over"])
    if y == 2020 and rel >= NETFX_2020_MAX:
        return Check("fixes.netfx", "warn",
                     f".NET Framework 4.7.2 or newer is in the bottle (Release {rel}): Revit 2020 crashes on start",
                     fix=rebuild(f), doc=DOC["netfx2020"])
    return Check("fixes.netfx", "ok", f".NET Framework is in the bottle (Release {rel})")


def fixes_checks(f, b):
    """The static checks of the profile's steps and of the steps that ran here (add-ins); a step the records show was
    never run is left to install.steps."""
    steps = list(f["profile"].get("STEPS") or [])
    ran = ran_steps(b)
    if ran is not None:
        steps = [s for s in steps if s in ran] + sorted(s for s in ran if s in FIXES and s not in steps)
    # one check per file, where the first step names it, with the strongest spec any step gives (richedit puts
    # msls31.dll in place, tlbpin replaces it with our shim: the shim's comparison is the one that tells)
    best, order = {}, []
    for step, sp in specs(f["profile"], f["year"], steps):
        key = spec_place(sp)[1] if len(sp) > 1 else sp[0]
        if key not in best:
            order.append(key)
        if key not in best or (sp[0] in ("shim", "pemark") and best[key][1][0] not in ("shim", "pemark")):
            best[key] = (step, sp)
    out = []
    for key in order:
        step, sp = best[key]
        out.append(runtime_check(f, b, step, sp[0]) if sp[0] in ("webview2", "dotnet", "netfx") else
                   file_check(f, b, step, sp))
    return out


def wine_bool(v):
    """A Mac driver option as Wine reads it (IS_OPTION_TRUE, winemac.drv): a string whose first letter is y, t or 1 is
    on; no value or another string is off. Another type is None: Wine reads its first bytes as text, we do not guess."""
    if v is None:
        return False
    if v[0] != "sz":
        return None
    return bool(v[1]) and v[1][0] in "yYtT1"


def effective_dpi(hkcu, hklm):
    """The DPI Wine uses (win32u get_system_dpi): HKCU's LogPixels unless missing or 0, then HKLM's, then 96. None when
    one it would read is not a number."""
    for v in (hkcu, hklm):
        if v is None:
            continue
        if v[0] != "dword" or v[1] is None:
            return None
        if v[1]:
            return v[1]
    return 96


def settings_checks(f, b):
    """What the retina and mackeys steps set, for a year whose profile has them: one note, or a warning for a state no
    ./revit set gives."""
    s = b.get("settings")
    if not s or s.get("mac") is None or s.get("hklm") is None:
        return []
    y, sfx = f["year"], f["sfx"]
    cmd = f"./revit set {y}{sfx}"
    mac, app = s["mac"] or {}, s.get("app") or {}
    hkcu, hklm = (s.get("hkcu") or {}).get("logpixels"), (s["hklm"] or {}).get("logpixels")
    retina, dpi = wine_bool(mac.get("retinamode")), effective_dpi(hkcu, hklm)
    keys = [wine_bool(app[k] if k in app else mac.get(k)) for k in KEY_VALUES]
    def val(v):
        return "none" if v is None else f"{v[1]}" if v[0] in ("sz", "dword") else f"{v[0]} {v[1]}"
    detail = f"RetinaMode {val(mac.get('retinamode'))}, LogPixels {val(hkcu)} (user), {val(hklm)} (machine); " + \
             ", ".join(f"{k} {val(app[k] if k in app else mac.get(k))}" + (" (Revit.exe)" if k in app else "")
                       for k in KEY_VALUES)
    out = []
    mode = None if retina is None or dpi is None else RETINA.get(("y" if retina else "n", dpi))
    if mode is None:
        what = "not readable" if retina is None or dpi is None else \
            f"Retina {'on' if retina else 'off'} at {dpi} DPI"
        out.append(Check("settings.retina", "warn", f"the display settings do not fit together ({what}): Revit may "
                         "look tiny, or large and blurry", detail=detail, fix=f"{cmd} retina=on"))
    if None in keys or len(set(keys)) > 1:
        out.append(Check("settings.keys", "warn", "the Cmd and Option keys are set only in part", detail=detail,
                         fix=f"{cmd} keys=mac"))
    if out:
        return out
    shown = {"on": "Retina on (192 DPI)", "compact": "Retina compact (144 DPI)", "off": "Retina off (96 DPI)"}[mode]
    shown += "; Cmd works as Ctrl" if keys[0] else "; Cmd works as Alt"
    fix = "" if mode != "off" and keys[0] else f"{cmd} retina=on keys=mac: sharp text, Cmd+S saves"
    return [Check("settings.display", "info", shown, detail=detail, fix=fix)]


def addin_checks(f):
    out = []
    for a in f.get("addins") or []:
        out.append(Check(f"addins.{a.get('id')}", "ok", f"{a.get('name') or a.get('id')} is installed"))
        if a.get("id") == "pdfprinter" and not f["host"].get("gs"):
            out.append(Check("addins.pdfprinter.gs", "warn",
                             "Revit PDF prints .ps files, not PDF: Ghostscript is not installed",
                             fix="brew install ghostscript"))
    if not out:
        out.append(Check("addins.none", "ok", "no add-ins installed"))
    return out


def pyrevit_agent_enabled(text):
    """The [agent] section of pyRevit_config.ini says enabled = true (any case; pyRevit writes Windows line ends)."""
    on, agent = False, False
    for line in text.replace("\r", "").split("\n"):
        t = line.strip()
        if t.startswith("["):
            agent = re.sub(r"\s", "", t).lower() == "[agent]"
        elif agent and "=" in t:
            k, v = t.split("=", 1)
            if k.strip().lower() == "enabled":
                on = re.sub(r"\s", "", v).lower() == "true"
    return on


def collect_pyrevit_agent(p):
    """pyRevit in bottle p: its clone, the agent runtime (pyRevit 7 and newer) and whether the agent is turned on."""
    j = os.path.join
    a = {"clone": os.path.isdir(j(p, PYREVIT_CLONE_REL)),
         "runtime": os.path.isfile(j(p, PYREVIT_CLONE_REL, "pyrevitlib/pyrevit/agent/_runner.py")), "enabled": False}
    try:
        with open(j(p, PYREVIT_CONFIG_REL), encoding="utf-8-sig", errors="replace") as fh:
            a["enabled"] = pyrevit_agent_enabled(fh.read())
    except OSError:
        pass
    return a


def pyrevit_agent_checks(f, b):
    """One ok line when pyRevit's agent is ready for ./revit mcp --server pyrevit; nothing otherwise (no problem)."""
    a = b.get("pyrevit_agent") or {}
    if a.get("clone") and a.get("runtime") and a.get("enabled"):
        return [Check("mcp.pyrevit.ready", "ok", f"pyRevit's agent is on: ./revit mcp {f['year']}{f['sfx']} --server pyrevit")]
    return []


def mcp_checks(f, b):
    """The Revit MCP Server, when its manifest or a variant folder is there: what ./revit mcp needs, from files only
    (whether the add-in opened its connection shows only while Revit runs: mcphost says so then)."""
    m, y, sfx = b.get("mcp") or {}, f["year"], f["sfx"]
    folders, man = m.get("folders") or {}, m.get("manifest")
    if man is None and not folders:
        return []
    ids = [i for i, _, _ in MCP_VARIANTS]
    vid = man if man in ids else next((i for i in ids if i in folders), "revitmcp")
    label = next(lb for i, _, lb in MCP_VARIANTS if i == vid)
    fix, out = f"./revit addins {y}{sfx} --only {vid} --accept-eula {vid}", []
    if man is None:
        out.append(Check("mcp.manifest", "fail", "the Revit MCP add-in has no manifest: Revit does not load it",
                         fix=fix))
    elif man == "":
        out.append(Check("mcp.manifest", "fail", "the Revit MCP add-in manifest points at a folder this project does "
                         "not know", fix=rebuild(f)))
    fo = folders.get(vid)
    if not fo or not fo["stdio"]:
        out.append(Check("mcp.files", "fail", f"the Revit MCP Server ({label}) files are missing", fix=fix))
    for s, exe in (("mcphost", "mcphost.exe"), ("mcppipes", "mcppipes.dll")):
        cur = (m.get("shims") or {}).get(s) or {}
        if fo and fo.get(s) is None:
            out.append(Check(f"mcp.{s}", "fail",
                             f"{exe} is missing next to the MCP Server: ./revit mcp cannot start it", fix=fix))
        elif fo and not cur.get("file"):
            out.append(Check(f"mcp.{s}", "fail", f"this project has no {exe} to compare the one next to the MCP Server "
                             "with: ./revit mcp cannot start it", fix=fix))
        elif fo and cur.get("sha256") and not cur.get("stale") and fo.get(s) != cur["sha256"]:
            out.append(Check(f"mcp.{s}", "fail", f"{exe} next to the MCP Server is not this project's current one",
                             fix=fix))
    if len(folders) > 1:
        out.append(Check("mcp.variants", "warn", "both variants of the Revit MCP Server have folders here; only one "
                         "can be used", fix=rebuild(f)))
    if not m.get("adp_marker") or not m.get("adp_core"):
        out.append(Check("mcp.adp", "fail", "Autodesk analytics (ADP), which the MCP add-in requires, is not installed "
                         "completely", fix=fix))
    if (m.get("today") or "") >= MCP_EXPIRES:
        out.append(Check("mcp.expired", "warn", "the Revit MCP Server Technical Preview stopped working in May 2028",
                         fix="get a newer one from your Autodesk account (docs/mcp.md)"))
    if not out:
        out.append(Check("mcp.ready", "ok", f"the Revit MCP Server ({label}) is ready: ./revit mcp {y}{sfx}"))
    return out


def day(t, now=None):
    """2 Oct, or 2 Oct 2025 in another year."""
    d, n = time.localtime(t), time.localtime(now)
    return f"{d.tm_mday} {MONTHS[d.tm_mon - 1]}" + ("" if d.tm_year == n.tm_year else f" {d.tm_year}")


def count(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def logs_checks(f, b):
    """A warning for each signature seen in the newest logs, with the date of the newest session it was seen in and
    what to do; the counts of the info signatures and what was read are in the JSON only."""
    lg = b.get("logs")
    if lg is None:
        return []
    out, seen, metrics = [], {}, {}
    for src in lg["sources"]:
        for sid, h in src["scan"]["hits"].items():
            seen.setdefault(sid, []).append((src, h))
        for sid, m in src["scan"]["metrics"].items():
            tot = metrics.setdefault(sid, {})
            for k, v in m.items():
                tot[k] = tot.get(k, 0) + v
    for sig in signatures.CATALOG:
        if sig.id not in seen:
            continue
        found = seen[sig.id]
        src = max(found, key=lambda sh: sh[0]["time"] or 0)[0]
        details = []
        for _, h in found:
            details += [x for x in h["details"] if x not in details]
        what = sig.meaning + (f" ({', '.join(details[:3])})" if details else "")
        when = f": seen in the {src['label']} of {day(src['time'])}" if src["time"] else ""
        where = "; ".join(f"{s['file']}: line {', '.join(map(str, h['lines'][:5]))}" +
                          (f" and {h['count'] - min(5, len(h['lines']))} more" if h["count"] > 5 else "") +
                          (f" of its last {count(s['scan']['lines'], 'line')}" if s["scan"].get("relative") else "")
                          for s, h in found)
        fix = sig.fix.replace(signatures.REBUILD, rebuild(f)) if sig.fix else f"see {TS}{sig.doc}"
        out.append(Check(f"logs.{sig.id}", "warn", what + when, detail=where, fix=fix,
                         doc=TS + sig.doc if sig.doc else ""))
    for sid, m in sorted(metrics.items()):
        out.append(Check(f"logs.{sid}", "info", signatures.BY_ID[sid].meaning, detail=json.dumps(m, sort_keys=True),
                         show=False))
    if lg["sources"]:   # what was read, folder by folder, short enough for a line of report.zip
        folders = {}
        for s in lg["sources"]:
            d, n = os.path.split(s["file"])
            folders.setdefault(d, []).append((n, s["scan"]))
        parts = []
        for d, files in folders.items():
            if len(files) > 3:
                parts.append(f"{d}: {count(len(files), 'log')}, {count(sum(sc['lines'] for _, sc in files), 'line')}")
                continue
            parts.append(f"{d}: " + ", ".join(
                f"{n} ({sc['size']} bytes) {count(sc['lines'], 'line')}" +
                (f" from byte {sc['start']} on" if sc.get("relative") else "") +
                (", stopped at the line cap" if sc["cut"] else "") for n, sc in files))
        out.append(Check("logs.read", "info", count(len(lg["sources"]), "log file") + " read",
                         detail="; ".join(parts), show=False))
        if not seen:
            out.append(Check("logs.signatures", "ok", "no known failure in the newest logs"))
    elif not lg["skipped"]:
        out.append(Check("logs.read", "info", "no logs of this bottle to read", show=False))
    if lg["skipped"]:
        out.append(Check("logs.skipped", "info", "logs older than the last install, not read: " +
                         ", ".join(f"the {x['label']} of {day(x['time'])}" for x in lg["skipped"] if x["time"]),
                         show=False))
    return out


def bottle_checks(f):
    b, y, name, out = f["b"], f["year"], f["bottle"], []
    if b.get("link"):
        return [Check("bottle.exists", "fail", f"bottle {name} is a link to another bottle",
                      fix="use the real bottle name")]
    if not b.get("exists"):
        return [Check("bottle.exists", "fail", f"there is no bottle {name}",
                      fix=f"to install Revit {y}: ./revit install {y}{f['sfx']}")]
    out.append(Check("bottle.exists", "ok", f"bottle {name} exists"))
    if b.get("clone") is not None:
        c = clone_check(f, "bottle.clone", name, b.get("years") or [], b["clone"])
        return out + [Check("bottle.clone", "fail", f"{name} is a temporary copy that ./revit test made, not a bottle "
                            "to check", detail=c.title, fix=c.fix or "wait until ./revit test finishes")]
    ys = b.get("years") or []
    if not ys:
        return out + [Check("bottle.year", "fail", f"bottle {name} does not look like a Revit bottle",
                            fix="if you do not need it, delete it in CrossOver")]
    if ys != [y]:
        return out + [Check("bottle.year", "fail", f"bottle {name} is for Revit {', '.join(map(str, ys))}, not {y}",
                            fix="check the year and the bottle name")]
    out.append(Check("bottle.year", "ok", f"bottle {name} is for Revit {y}"))
    gone = [n for n, ok in sorted((b.get("registry") or {}).items()) if not ok]
    if gone:
        out.append(Check("bottle.registry", "fail", f"the bottle's registry is missing ({', '.join(gone)})",
                         fix=rebuild(f), doc=DOC["start-over"]))
    else:
        out.append(Check("bottle.registry", "ok", "the bottle has its registry"))
    act = b.get("activity")
    if act == "active":
        out.append(Check("bottle.activity", "info", f"Revit or its background services run in {name}",
                         detail="what Wine changes reaches the registry on disk up to about 30 s later"))
    elif act == "leftover":
        out.append(Check("bottle.activity", "warn", f"Windows programs of an ended Wine session still run in {name}",
                         detail="their wineserver is gone (it crashed or was killed); they keep the bottle busy",
                         fix=f"./revit stop {y}{f['sfx']}"))
    elif act == "stopped":
        out.append(Check("bottle.activity", "ok", f"nothing runs in {name}"))
    else:
        out.append(Check("bottle.activity", "info", f"whether anything runs in {name} could not be read", show=False))
    if not b.get("revit_exe"):
        out.append(Check("bottle.revit", "fail", "Revit.exe is not in the bottle", fix=rebuild(f),
                         doc=DOC["start-over"]))
    else:
        out.append(Check("bottle.revit", "ok", "Revit.exe is in the bottle"))
    d = b.get("documents") or {}
    if d.get("kind") == "link":
        out.append(Check("bottle.documents", "ok", f"Documents in the bottle is your Mac folder {d['target']}"))
    elif d.get("kind") == "dangling":
        out.append(Check("bottle.documents", "warn",
                         f"Documents in the bottle points to a folder that is not there: {d['target']}",
                         fix="connect the disk that holds it; files Revit saves to Documents go there"))
    elif d.get("kind") == "folder":
        out.append(Check("bottle.documents", "info",
                         "Documents in the bottle is not linked to your Mac: files in it are deleted with the bottle"))
    out += app_checks(f, b)
    out += install_checks(f, b) + since_install(f, b)
    if b.get("revit_exe"):
        out += fixes_checks(f, b) + settings_checks(f, b) + addin_checks(f) + mcp_checks(f, b) + pyrevit_agent_checks(f, b)
    return out + logs_checks(f, b)


def run_checks(f):
    """The checks, from collect()'s facts (or a test's), in group order."""
    out = host_checks(f) + crossover_checks(f)
    out += bottles_checks(f) if f.get("year") is None else bottle_checks(f)
    return sorted(out, key=lambda c: GROUPS.index(c.group))


def summary(checks):
    s = {k: sum(1 for c in checks if c.status == k) for k in ("fail", "warn", "ok", "info")}
    s["checks"] = len(checks)
    return s


def render(checks, all_=False):
    """The lines for the terminal: problems with their fix, notes, then the summary line; all_ adds what passed."""
    lines = []
    for c in checks:
        if c.status in ("fail", "warn"):
            lines.append(f"  {'✗' if c.status == 'fail' else '!'} {c.title}")
            if c.fix:
                lines.append(f"      fix: {c.fix}")
        elif c.status == "info" and c.show:
            lines.append(f"  · {c.title}")
            if c.fix:
                lines.append(f"      {c.fix}")
        elif c.status == "ok" and all_:
            lines.append(f"  ✓ {c.title}")
    s = summary(checks)
    if not s["fail"] and not s["warn"]:
        lines.append(f"  ✓ no problems found ({s['checks']} checks)")
    else:
        parts_ = [f"{s['fail']} problem{'s' if s['fail'] != 1 else ''}"] if s["fail"] else []
        parts_ += [f"{s['warn']} warning{'s' if s['warn'] != 1 else ''}"] if s["warn"] else []
        lines.append(f"  {' and '.join(parts_)} ({s['checks']} checks)")
    return lines


def main(argv=None):
    p = argparse.ArgumentParser(prog="doctor.py", description="Check this Mac, CrossOver and a Revit bottle.")
    for a in ("--root", "--data", "--cx", "--bottles"):
        p.add_argument(a, required=True)
    for a in ("--shims", "--lock", "--cx-tested", "--engine", "--shims-release", "--bottle", "--profile-json"):
        p.add_argument(a)
    p.add_argument("--year", type=int)
    p.add_argument("--addins", default="[]")
    p.add_argument("--json", action="store_true")
    p.add_argument("--all", action="store_true")
    o = p.parse_args(argv)
    if o.year is not None and not (o.bottle and o.profile_json):
        p.error("--year needs --bottle and --profile-json")
    profile, addins = {}, []
    try:
        if o.profile_json:
            if o.profile_json == "-":
                profile = json.load(sys.stdin)
            else:
                with open(o.profile_json, encoding="utf-8") as f:
                    profile = json.load(f)
        addins = json.loads(o.addins)
    except (OSError, ValueError) as e:
        p.error(f"cannot read the profile or the add-ins: {e}")
    if not isinstance(profile, dict) or not isinstance(addins, list):
        p.error("the profile is a JSON object, the add-ins a JSON list")
    ctx = Ctx(o.root, o.data, o.cx, o.bottles, o.shims, o.lock, o.cx_tested, o.engine, o.shims_release,
              o.year, o.bottle, profile, addins)
    try:
        checks = run_checks(collect(ctx))
    except Exception as e:   # still one answer, for ./revit report too: the error's kind and line, no paths or values
        tb = e.__traceback__
        while tb.tb_next:
            tb = tb.tb_next
        checks = [Check("doctor.internal", "fail", f"doctor could not finish: {type(e).__name__} at line {tb.tb_lineno}",
                        fix="report a problem with this line")]
    s = summary(checks)
    if o.json:
        print(json.dumps({"checks": [c.json() for c in checks], "summary": s}, ensure_ascii=False,
                         separators=(",", ":")))
    else:
        what = f"Revit {o.year} (bottle {o.bottle}), CrossOver and this Mac" if o.year else "this Mac and CrossOver"
        print(f"Checking {what}…")
        print("\n".join(render(checks, o.all)))
    return 1 if s["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
