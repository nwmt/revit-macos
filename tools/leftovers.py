#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Programs left running after Revit, Wine or the app ended, and closing them (./revit cleanup, the app's Close all).

  leftovers.py scan  --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json]
  leftovers.py close --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json]

What counts as left over:
  wine    Windows programs of a bottle whose wineserver is gone (it crashed or was killed: they keep running, some at
          100% CPU, and `wineserver -k` no longer reaches them), or whose bottle folder was deleted; Windows programs
          in no bottle while no wineserver runs at all (conhost.exe, winewrapper.exe)
  helper  the app's Trackpad helper whose app (--parent <pid>:<start>) is gone; the Mac side of
          ./revit mcp --server python whose MCP client is gone
  gdrive  ./revit gdrive warm that has run for 30 minutes and has the same folders open a few seconds apart (a listing
          Google Drive never answers)
With --all also the bottles that still run without Revit (Autodesk's background services). A bottle where Revit, our MCP
launcher or the app's hittest runs is never touched: it is listed as skipped (./revit stop ends it).

close: per bottle `wineserver -k` first, then TERM to what is left, KILL after 3 s. It scans again first and closes
only what that scan finds. The bottle of a process comes from its open files (lsof). Exit 0 when nothing is left,
1 when a program could not be ended. REVIT_CLEANUP_AGE (default 60 s: a Revit that is starting has no wineserver yet)
and REVIT_GDRIVE_STUCK_AGE (default 1800 s) are the youngest ages counted; REVIT_CLEANUP_ONLY (tests only) counts only
processes whose command line contains that text. Run with python3 -I -B.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

WINE_ANY = re.compile(r"wine|\.exe", re.I)   # what ./revit stop looks at too (bottle_leftovers)
WINE_LOOSE = re.compile(r"^[A-Za-z]:\\|(^|/)winewrapper\.exe( |$)", re.I)   # a Wine program even in no bottle
IN_USE = re.compile(r"(^|[\\/ ])(Revit|mcphost|hittest)\.exe( |$)", re.I)
TRACKPAD = re.compile(r" Trackpad --session \S+ --parent (\d+):(.+?) --engine ")   # <App> Trackpad (HelperArgs)
PYMCP = " revit-macos-python-mcp "
WATCH = "/watch-server.pl "
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}


def secs(etime):
    """ps etime ([[dd-]hh:]mm:ss) → seconds."""
    d = 0
    if "-" in etime:
        d, etime = etime.split("-", 1)
    parts = [int(x) for x in etime.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return int(d) * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]


def age_text(s):
    if s >= 86400:
        return f"{s // 86400} d {s % 86400 // 3600} h"
    if s >= 3600:
        return f"{s // 3600} h {s % 3600 // 60} min"
    return f"{s // 60} min" if s >= 60 else f"{s} s"


def out(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                              env=ENV, timeout=30).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return ""


def processes():
    """This user's processes: {pid: {ppid, etime, cpu, comm, command}}."""
    procs, uid = {}, str(os.getuid())
    for line in out(["ps", "-axww", "-o", "pid=,ppid=,uid=,etime=,%cpu=,command="]).splitlines():
        f = line.split(None, 5)
        if len(f) < 6 or f[2] != uid or not f[0].isdigit():
            continue
        procs[int(f[0])] = {"ppid": int(f[1]), "age": secs(f[3]), "cpu": float(f[4]), "command": f[5], "comm": ""}
    for line in out(["ps", "-axww", "-o", "pid=,comm="]).splitlines():
        f = line.split(None, 1)
        if len(f) == 2 and f[0].isdigit() and int(f[0]) in procs:
            procs[int(f[0])]["comm"] = f[1]
    return procs


def open_files(pids):
    """{pid: [(type, name, fd)]} from one lsof call; a process that ended meanwhile only drops out."""
    files = {}
    if not pids:
        return files
    p = None
    for line in out(["lsof", "-w", "-n", "-P", "-p", ",".join(map(str, sorted(pids))), "-Fftn"]).splitlines():
        if line.startswith("p"):
            p = int(line[1:]); files.setdefault(p, []); fd = t = ""
        elif line.startswith("f") and p is not None:
            fd, t = line[1:], ""
        elif line.startswith("t") and p is not None:
            t = line[1:]
        elif line.startswith("n") and p is not None:
            files[p].append((t, line[1:], fd))
    return files


def bottle_of(names, roots):
    """The bottle a process's open files are in: the first name under one of roots (the Bottles folder, and its
    real path), or None."""
    for x in names:
        n = x[1]
        for r in roots:
            if n.startswith(r + "/"):
                return n[len(r) + 1:].split("/", 1)[0]
    return None


def short(command):
    """A process's name for people: winedevice.exe, Mac BIM Dock Trackpad, gdrive.py warm."""
    if TRACKPAD.search(command):
        return command[:command.index(" --session ")].rsplit("/", 1)[-1]
    if "/gdrive.py warm " in command:
        return "gdrive.py warm"
    if PYMCP in command:
        return "python MCP server"
    m = re.search(r"([^\\/]+\.exe)( |$)", command, re.I)
    if m:
        return m.group(1)
    return command.split(" ", 1)[0].rsplit("/", 1)[-1]


def classify(procs, files, bottles, bottle=None, everything=False, started=None, stuck=None, now_pid=None):
    """The leftovers and the bottles skipped. procs and files as processes() and open_files() give them; started(pid)
    = that process's ps lstart (or None), stuck(pid) = True when a gdrive warm makes no progress."""
    roots = [bottles]
    real = os.path.realpath(bottles)
    if real != bottles:
        roots.append(real)
    age_min = int(os.environ.get("REVIT_CLEANUP_AGE", "60"))
    stuck_min = int(os.environ.get("REVIT_GDRIVE_STUCK_AGE", "1800"))
    only = os.environ.get("REVIT_CLEANUP_ONLY", "")
    mine = {now_pid or os.getpid(), os.getppid()}
    procs = {p: v for p, v in procs.items() if p not in mine and (not only or only in v["command"])}
    wine, servers, in_use = {}, set(), set()
    for p, v in procs.items():
        c = v["command"]
        if WATCH in c or PYMCP in c or "/gdrive.py " in c or TRACKPAD.search(c):
            continue
        is_server = v["comm"].rsplit("/", 1)[-1] == "wineserver"
        if not is_server and not WINE_ANY.search(c):
            continue
        b = bottle_of(files.get(p, []), roots)
        if is_server:
            servers.add(b)
            if b is None:
                continue
        elif b is None and not WINE_LOOSE.search(c):
            continue
        if IN_USE.search(c) and b is not None:
            in_use.add(b)
        wine[p] = b
    items, skipped = [], []

    def add(p, kind, reason, b=None):
        v = procs[p]
        items.append({"pid": p, "kind": kind, "reason": reason, "bottle": b, "name": short(v["command"]),
                      "cpu": v["cpu"], "age_s": v["age"]})

    for b in sorted({b for b in wine.values() if b is not None} | in_use):
        if bottle is not None and b != bottle:
            continue
        gone = not os.path.isdir(os.path.join(bottles, b))
        if b in in_use:
            skipped.append({"bottle": b, "why": "revit_running"})
            continue
        if gone:
            reason = "bottle_gone"
        elif b not in servers:
            reason = "no_wineserver"
        elif everything:
            reason = "idle"
        else:
            continue
        for p in sorted(q for q, x in wine.items() if x == b):
            if procs[p]["age"] >= age_min or reason == "idle":
                add(p, "wine", reason, b)
    if bottle is None and not servers:   # no wineserver at all: a Wine program in no bottle has none either
        for p in sorted(q for q, x in wine.items() if x is None):
            if procs[p]["age"] >= age_min:
                add(p, "wine", "no_wineserver")
    for p, v in sorted(procs.items()):
        c = v["command"]
        m = TRACKPAD.search(c)
        if m and bottle is None:
            parent, start = int(m.group(1)), m.group(2).strip()
            if (started(parent) if started else None) != start:
                add(p, "helper", "parent_gone")
        elif PYMCP in c and v["ppid"] == 1 and bottle is None:
            add(p, "helper", "parent_gone")
        elif "/gdrive.py warm " in c and v["age"] >= stuck_min:
            b = bottle_of([("", c[c.index("/gdrive.py warm ") + 16:])], roots)   # its first argument, the bottle
            b = b.split(" ", 1)[0] if b else None   # (bottle names have no spaces)
            if (bottle is None or b == bottle) and stuck and stuck(p):
                add(p, "gdrive", "stuck", b)
    return items, skipped


def lstart(pid):
    s = out(["ps", "-o", "lstart=", "-p", str(pid)]).strip()
    return s or None


def gdrive_stuck(pid, wait=None):
    """The same folders open now and a moment later: the walk does not move on. No folder open (its working folder
    does not count): not stuck."""
    def dirs():
        return sorted(x[1] for x in open_files([pid]).get(pid, []) if x[0] == "DIR" and x[2] not in ("cwd", "rtd"))
    a = dirs()
    if not a:
        return False
    time.sleep(float(os.environ.get("REVIT_GDRIVE_SAMPLE", "2")) if wait is None else wait)
    return dirs() == a


def scan(bottles, bottle=None, everything=False):
    procs = processes()
    files = open_files([p for p, v in procs.items() if WINE_ANY.search(v["command"])
                        or v["comm"].endswith("/wineserver") or v["comm"] == "wineserver"])
    return classify(procs, files, bottles, bottle, everything, started=lstart, stuck=gdrive_stuck)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # a zombie (ended, its parent has not waited yet) is gone for us
    return out(["ps", "-o", "stat=", "-p", str(pid)]).strip()[:1] not in ("", "Z")


def wait_gone(pids, secs):
    end = time.monotonic() + secs
    while True:
        left = [p for p in pids if alive(p)]
        if not left or time.monotonic() >= end:
            return left
        time.sleep(0.1)


def signal_all(pids, sig):
    for p in pids:
        try:
            os.kill(p, sig)
        except OSError:
            pass


def close(bottles, cx, items):
    """Ends items: wineserver -k for each bottle that is still there, then TERM, then KILL. → the PIDs still alive."""
    for b in sorted({i["bottle"] for i in items if i["kind"] == "wine" and i["bottle"]}):
        prefix = os.path.join(bottles, b)
        if os.path.isdir(prefix):
            try:
                subprocess.run([os.path.join(cx, "bin", "wineserver"), "-k"], env=dict(os.environ, WINEPREFIX=prefix),
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                pass
    pids = [i["pid"] for i in items]
    left = wait_gone(pids, 3 if any(i["kind"] == "wine" and i["bottle"] for i in items) else 0)
    signal_all(left, signal.SIGTERM)
    left = wait_gone(left, 3)
    signal_all(left, signal.SIGKILL)
    return wait_gone(left, 2)


REASONS = {"no_wineserver": "Wine stopped, the program stayed", "bottle_gone": "its bottle was deleted",
           "idle": "runs without Revit", "parent_gone": "the program that started it is gone",
           "stuck": "a Google Drive folder does not answer"}


def year_of(bottles, b):
    """The Revit year in a bottle's description (new-bottle.sh writes it), or <year>."""
    try:
        with open(os.path.join(bottles, b, "cxbottle.conf"), encoding="utf-8", errors="replace") as f:
            m = re.search(r'^"Description" = "Revit (\d{4})"$', f.read(), re.M)
            return m.group(1) if m else "<year>"
    except OSError:
        return "<year>"


def line(i):
    where = i["bottle"] or "no bottle"
    if i["reason"] == "bottle_gone":
        where += " (deleted)"
    return f"  {i['pid']:>6}  {i['name']:<24} {where:<20} CPU {i['cpu']:.0f}%  {age_text(i['age_s']):<12} {REASONS[i['reason']]}"


def main(argv):
    if not argv or argv[0] not in ("scan", "close"):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, a, opts, flags = argv[0], argv[1:], {}, set()
    while a:
        if a[0] in ("--bottles", "--cx", "--bottle") and len(a) >= 2:
            opts[a[0][2:]] = a[1]; a = a[2:]
        elif a[0] in ("--all", "--json"):
            flags.add(a[0][2:]); a = a[1:]
        else:
            print(f"leftovers.py: unknown argument {a[0]}", file=sys.stderr)
            return 2
    if "bottles" not in opts or cmd == "close" and "cx" not in opts:
        print("leftovers.py: --bottles and --cx are needed", file=sys.stderr)
        return 2
    items, skipped = scan(opts["bottles"], opts.get("bottle"), "all" in flags)
    left = close(opts["bottles"], opts["cx"], items) if cmd == "close" and items else []
    if "json" in flags:
        d = {"items": items, "skipped": skipped}
        if cmd == "close":
            d["closed"] = [i["pid"] for i in items if i["pid"] not in left]
            d["left"] = left
        print(json.dumps(d))
        return 1 if left else 0
    for s in skipped:
        print(f"Skipped {s['bottle']}: Revit runs there. To end it: ./revit stop {year_of(opts['bottles'], s['bottle'])} {s['bottle']}")
    if not items:
        print("Nothing is left running." if not skipped else "Nothing else is left running.")
        return 0
    print("Left running:" if cmd == "scan" else "Closing:")
    for i in items:
        print(line(i))
    if cmd == "scan":
        return 0
    if left:
        print(f"Could not end {len(left)} program(s): {' '.join(map(str, left))}. Restart the Mac.")
        return 1
    print(f"Closed {len(items)} program(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
