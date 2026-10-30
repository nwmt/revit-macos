#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Programs left running after Revit, Wine or the app ended, and closing them (./revit cleanup, the app's Close all).

  leftovers.py scan  --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json]
  leftovers.py close --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json] [--targets <pid>:<start>,…]

What counts as left over:
  wine    Windows programs of a bottle whose wineserver is gone (it crashed or was killed: they keep running, some at
          100% CPU, and `wineserver -k` no longer reaches them), or whose bottle folder was deleted; Windows programs
          in no bottle while no wineserver runs at all (conhost.exe, winewrapper.exe). A Wine program is told by its
          executable (a Windows path, *.exe, CrossOver's wine binaries), never by its arguments or open files: `less` on a
          bottle's log is not one
  helper  the app's Trackpad helper whose app (--parent <pid>:<start>) is gone; the Mac side of
          ./revit mcp --server python whose MCP client is gone
  gdrive  ./revit gdrive warm whose last progress (its heartbeat, tools/gdrive.py) is 30 minutes old: a listing Google
          Drive never answers
With --all also the bottles that still run without Revit (Autodesk's background services). A bottle where Revit, our MCP
launcher or the app's hittest runs is never touched: it is listed as skipped (./revit stop ends it). When a wineserver
runs whose bottle cannot be told, no bottle counts as having none (skipped as wineserver_unknown).

The bottle of a process comes from its open files (lsof); a wineserver's also from its server folder
(/tmp/.wine-<uid>/server-<dev>-<inode> of its bottle). Each item carries its start (epoch seconds from ps lstart): close
signals a PID only while that start is still the one scanned, so a reused PID is never hit.

close: scans once, then ends exactly what that scan found (with --targets: only those of them, the list a person
approved; anything new waits for the next ask). Programs Wine left behind are ended by PID only, TERM then KILL after
3 s. A bottle that runs without Revit (--all) gets `wineserver -k` first, after a look right before it that nothing of
Revit started there meanwhile. Exit 0 when nothing is left, 1 when a program could not be ended. REVIT_CLEANUP_AGE
(default 60 s: a Revit that is starting has no wineserver yet) and REVIT_GDRIVE_STUCK_AGE (default 1800 s) are the
youngest ages counted; REVIT_CLEANUP_ONLY (tests only) counts only processes whose command line contains that text.
Run with python3 -I -B.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

WINE_EXE = re.compile(r"^[A-Za-z]:\\|\.exe$|(^|/)(wineserver|wine|wine64|wineloader|wine-preloader|wine64-preloader)$", re.I)
IN_USE = re.compile(r"(^|[\\/ ])(Revit|mcphost|hittest)\.exe( |$)", re.I)   # in a Wine program's command line
SERVER_DIR = re.compile(r"/\.wine-\d+/server-([0-9a-f]+)-([0-9a-f]+)$")   # wineserver's cwd: its bottle's dev, inode
TRACKPAD = re.compile(r" Trackpad --session \S+ --parent (\d+):(.+?) --engine ")   # <App> Trackpad (HelperArgs)
PYMCP = " revit-macos-python-mcp "
WARM = "/gdrive.py warm "
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


def server_bottle(names, bottles):
    """A wineserver's bottle from its server folder: the bottle whose folder has that device and inode, or None."""
    for x in names:
        m = SERVER_DIR.search(x[1])
        if not m:
            continue
        dev, ino = int(m.group(1), 16), int(m.group(2), 16)
        try:
            with os.scandir(bottles) as it:
                for e in it:
                    st = e.stat(follow_symlinks=False)
                    if e.is_dir(follow_symlinks=False) and (st.st_dev, st.st_ino) == (dev, ino):
                        return e.name
        except OSError:
            return None
    return None


def is_wine(v):
    """A Wine program, by its executable (ps comm: argv[0]), not by what it has open or its arguments."""
    return bool(WINE_EXE.search(v["comm"]))


def is_server(v):
    return v["comm"].rsplit("/", 1)[-1] == "wineserver"


def short(command):
    """A process's name for people: winedevice.exe, Mac BIM Dock Trackpad, gdrive.py warm."""
    if TRACKPAD.search(command):
        return command[:command.index(" --session ")].rsplit("/", 1)[-1]
    if WARM in command:
        return "gdrive.py warm"
    if PYMCP in command:
        return "python MCP server"
    m = re.search(r"([^\\/]+\.exe)( |$)", command, re.I)
    if m:
        return m.group(1)
    return command.split(" ", 1)[0].rsplit("/", 1)[-1]


def heartbeat(bottles, b, pid):
    """The progress a gdrive warm wrote (tools/gdrive.py Beat): {pid, started, progress} or None."""
    try:
        with open(os.path.join(bottles, b, "revit-macos", f"gdrive-warm-{pid}"), encoding="utf-8") as f:
            d = json.load(f)
        return d if d.get("pid") == pid else None
    except (OSError, ValueError, AttributeError):
        return None


def warm_stuck(bottles, b, pid, age, now=None):
    """No progress for REVIT_GDRIVE_STUCK_AGE s: by its heartbeat; without one (an older engine), since it started."""
    now = time.time() if now is None else now
    limit = int(os.environ.get("REVIT_GDRIVE_STUCK_AGE", "1800"))
    hb = heartbeat(bottles, b, pid) if b else None
    if hb is not None and hb.get("started", 0) >= now - age - 60:   # written by this process, not an earlier one
        return now - hb.get("progress", 0) >= limit
    return age >= limit


def classify(procs, files, bottles, bottle=None, everything=False, started=None, now_pid=None, now=None):
    """The leftovers and the bottles skipped. procs and files as processes() and open_files() give them; started(pid)
    = that process's ps lstart (or None)."""
    roots = [bottles]
    real = os.path.realpath(bottles)
    if real != bottles:
        roots.append(real)
    age_min = int(os.environ.get("REVIT_CLEANUP_AGE", "60"))
    only = os.environ.get("REVIT_CLEANUP_ONLY", "")
    mine = {now_pid or os.getpid(), os.getppid()}
    procs = {p: v for p, v in procs.items() if p not in mine and (not only or only in v["command"])}
    wine, servers, in_use, unknown = {}, set(), set(), False
    for p, v in procs.items():
        if not is_wine(v):
            continue
        b = bottle_of(files.get(p, []), roots)
        if is_server(v):
            b = b or server_bottle(files.get(p, []), bottles)
            if b is None:
                unknown = True   # a wineserver of some bottle: which one runs none cannot be told
                continue
            servers.add(b)
        if IN_USE.search(v["command"]) and b is not None:
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
        if b in in_use:
            skipped.append({"bottle": b, "why": "revit_running"})
            continue
        if not os.path.isdir(os.path.join(bottles, b)):
            reason = "bottle_gone"
        elif b in servers:
            if not everything:
                continue
            reason = "idle"
        elif unknown:
            skipped.append({"bottle": b, "why": "wineserver_unknown"})
            continue
        else:
            reason = "no_wineserver"
        for p in sorted(q for q, x in wine.items() if x == b):
            if procs[p]["age"] >= age_min or reason == "idle":
                add(p, "wine", reason, b)
    if bottle is None and not servers and not unknown:   # no wineserver at all: a Wine program in no bottle has none either
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
        elif WARM in c:
            b = bottle_of([("", c[c.index(WARM) + len(WARM):])], roots)   # its first argument, the bottle
            b = b.split(" ", 1)[0] if b else None   # (bottle names have no spaces)
            if (bottle is None or b == bottle) and warm_stuck(bottles, b, p, v["age"], now):
                add(p, "gdrive", "stuck", b)
    return items, skipped


def lstart(pid):
    s = out(["ps", "-o", "lstart=", "-p", str(pid)]).strip()
    return s or None


def starts(pids):
    """{pid: start in epoch seconds} from ps lstart; a process that is gone is not in it."""
    got = {}
    if not pids:
        return got
    for line in out(["ps", "-o", "pid=,lstart=", "-p", ",".join(map(str, sorted(pids)))]).splitlines():
        f = line.split(None, 1)
        try:
            got[int(f[0])] = int(time.mktime(time.strptime(f[1].strip(), "%a %b %d %H:%M:%S %Y")))
        except (IndexError, ValueError):
            pass
    return got


def scan(bottles, bottle=None, everything=False):
    """The leftovers, each with its start, and the bottles skipped."""
    procs = processes()
    files = open_files([p for p, v in procs.items() if is_wine(v)])
    items, skipped = classify(procs, files, bottles, bottle, everything, started=lstart)
    st = starts([i["pid"] for i in items])
    items = [dict(i, start=st[i["pid"]]) for i in items if i["pid"] in st]   # one that ended meanwhile drops out
    return items, skipped


def still(items):
    """Those of items that still run as the same process (its start unchanged; a zombie has ended)."""
    st = starts([i["pid"] for i in items])
    stat = {}
    if st:
        for line in out(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, sorted(st)))]).splitlines():
            f = line.split()
            if len(f) == 2 and f[0].isdigit():
                stat[int(f[0])] = f[1]
    return [i for i in items if st.get(i["pid"]) == i["start"] and not stat.get(i["pid"], "Z").startswith("Z")]


def wait_gone(items, secs):
    end = time.monotonic() + secs
    while True:
        left = still(items)
        if not left or time.monotonic() >= end:
            return left
        time.sleep(0.1)


def signal_all(items, sig):
    for i in still(items):   # checked right before: a PID taken by another process meanwhile is not signalled
        try:
            os.kill(i["pid"], sig)
        except OSError:
            pass


def close(bottles, cx, items):
    """Ends items. → (the items still running, the bottles left alone because Revit started there meanwhile)."""
    spared = []
    for b in sorted({i["bottle"] for i in items if i["reason"] == "idle"}):
        prefix = os.path.join(bottles, b)
        now, sk = scan(bottles, b, True)   # right before -k: Revit (or our MCP, hittest) may have started there
        if any(s["bottle"] == b for s in sk) or not os.path.isdir(prefix):
            spared.append(b)
            continue
        try:
            subprocess.run([os.path.join(cx, "bin", "wineserver"), "-k"], env=dict(os.environ, WINEPREFIX=prefix),
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            pass
    items = [i for i in items if i["bottle"] not in spared or i["reason"] != "idle"]
    left = wait_gone(items, 3 if any(i["reason"] == "idle" for i in items) else 0)
    signal_all(left, signal.SIGTERM)
    left = wait_gone(left, 3)
    signal_all(left, signal.SIGKILL)
    return wait_gone(left, 2), spared


REASONS = {"no_wineserver": "Wine stopped, the program stayed", "bottle_gone": "its bottle was deleted",
           "idle": "runs without Revit", "parent_gone": "the program that started it is gone",
           "stuck": "a Google Drive folder does not answer"}
SKIPPED = {"revit_running": "Revit runs there. To end it: ./revit stop {year} {bottle}",
           "wineserver_unknown": "a wineserver runs whose bottle cannot be told, so whether this one has one is not known",
           "revit_started": "Revit started there meanwhile"}


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


def targets_of(text):
    """--targets <pid>:<start>,…: the (pid, start) pairs a person approved."""
    got = set()
    for t in text.split(","):
        pid, _, st = t.partition(":")
        if not (pid.isdigit() and st.isdigit()):
            raise ValueError(t)
        got.add((int(pid), int(st)))
    return got


def main(argv):
    if not argv or argv[0] not in ("scan", "close"):
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, a, opts, flags = argv[0], argv[1:], {}, set()
    while a:
        if a[0] in ("--bottles", "--cx", "--bottle", "--targets") and len(a) >= 2:
            opts[a[0][2:]] = a[1]; a = a[2:]
        elif a[0] in ("--all", "--json"):
            flags.add(a[0][2:]); a = a[1:]
        else:
            print(f"leftovers.py: unknown argument {a[0]}", file=sys.stderr)
            return 2
    if "bottles" not in opts or cmd == "close" and "cx" not in opts:
        print("leftovers.py: --bottles and --cx are needed", file=sys.stderr)
        return 2
    try:
        want = targets_of(opts["targets"]) if "targets" in opts else None
    except ValueError as e:
        print(f"leftovers.py: --targets takes <pid>:<start>,…, not {e}", file=sys.stderr)
        return 2
    items, skipped = scan(opts["bottles"], opts.get("bottle"), "all" in flags)
    if want is not None:   # only what was approved, and only while it is the same process
        items = [i for i in items if (i["pid"], i["start"]) in want]
    left, spared = close(opts["bottles"], opts["cx"], items) if cmd == "close" and items else ([], [])
    skipped += [{"bottle": b, "why": "revit_started"} for b in spared]
    kept = [i for i in items if i["reason"] == "idle" and i["bottle"] in spared]
    done = [i for i in items if i not in left and i not in kept]
    if "json" in flags:
        d = {"items": items, "skipped": skipped}
        if cmd == "close":
            d["closed"] = [i["pid"] for i in done]
            d["left"] = [i["pid"] for i in left]
        print(json.dumps(d))
        return 1 if left else 0
    for s in skipped:
        print(f"Skipped {s['bottle']}: " + SKIPPED[s["why"]].format(year=year_of(opts["bottles"], s["bottle"]), bottle=s["bottle"]))
    if not items:
        print("Nothing is left running." if not skipped else "Nothing else is left running.")
        return 0
    print("Left running:" if cmd == "scan" else "Closing:")
    for i in items:
        print(line(i))
    if cmd == "scan":
        return 0
    if left:
        print(f"Could not end {len(left)} program(s): {' '.join(str(i['pid']) for i in left)}. Restart the Mac.")
        return 1
    print(f"Closed {len(done)} program(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
