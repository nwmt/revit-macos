#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Programs left running after Revit, Wine or the app ended, and closing them (./revit cleanup, the app's Close all).

  leftovers.py scan  --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json]
  leftovers.py close --bottles <dir> --cx <CrossOver> [--bottle <name>] [--all] [--json] [--targets <pid>:<start>,…]

One snapshot of this user's processes, each by what the kernel says: its executable (proc_pidpath), its start in
microseconds, its arguments and its environment (KERN_PROCARGS2). A Wine process is one whose executable is inside the
CrossOver folder (--cx; CrossOver's own window is outside it); its bottle is its WINEPREFIX. A process whose executable
cannot be read is left alone.

Without --all, what is left over (orphans):
  wine    Wine processes of a bottle that has no wineserver (it crashed or was killed: they keep running, some at 100%
          CPU, and nothing of Wine reaches them any more) or whose folder was deleted. Not: a process younger than
          REVIT_CLEANUP_AGE s (default 60: a Revit that is starting has no wineserver yet), one without a WINEPREFIX, a
          bottle where Revit is among them (skipped: --all closes it, unsaved changes are lost), Wine of a prefix
          outside the Bottles folder (another program's: it neither counts nor blocks)
  helper  the app's Trackpad helper whose app (--parent <pid>:<start>) is gone; the Mac side of
          ./revit mcp --server python whose MCP client is gone
  gdrive  ./revit gdrive warm whose own heartbeat (tools/gdrive.py) shows no progress for REVIT_GDRIVE_STUCK_AGE s
          (default 1800); no heartbeat or an unreadable one is not stuck
With --all: every Wine process of this user (Revit too, without saving; also when a wineserver hangs), the helpers whose
parent is gone and every gdrive warm.

close: ends what its own scan listed (with --targets: only those of them a person approved), by PID: TERM, then KILL
after 3 s. Right before each signal the PID must still have the start and executable scanned, so a PID taken by
another process is never hit. No wineserver -k, no lock. Exit 0 when nothing is left, 1 when a program could not be
ended. REVIT_CLEANUP_ONLY (tests, narrowed runs) counts only processes whose arguments or WINEPREFIX contain that text.
Run with python3 -I -B.
"""
import ctypes
import json
import os
import re
import signal
import struct
import subprocess
import sys
import time

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBC = ctypes.CDLL(None, use_errno=True)
TRACKPAD = re.compile(r"/Contents/Helpers/[^/]+ Trackpad\.app/Contents/MacOS/[^/]+ Trackpad$")   # <App> Trackpad
REVIT = re.compile(r"(^|\\)Revit\.exe$", re.I)   # argv[0] of Revit, as Wine sets it
PYMCP = "revit-macos-python-mcp"
SZOMB = 5


class BsdInfo(ctypes.Structure):   # sys/proc_info.h: struct proc_bsdinfo (PROC_PIDTBSDINFO)
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
                ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32),
                ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
                ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32), ("comm", ctypes.c_char * 16),
                ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32), ("tpgid", ctypes.c_uint32),
                ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]


def bsdinfo(pid):
    i = BsdInfo()
    n = LIBPROC.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(i), ctypes.sizeof(i))
    return i if n == ctypes.sizeof(i) else None


def exe_of(pid):
    buf = ctypes.create_string_buffer(4096)
    n = LIBPROC.proc_pidpath(pid, buf, 4096)
    return os.fsdecode(buf.value) if n > 0 else None


def args_env(pid):
    """(argv, env) from KERN_PROCARGS2, or ([], {}) when it cannot be read."""
    mib = (ctypes.c_int * 3)(1, 49, pid)   # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if LIBC.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return [], {}
    buf = ctypes.create_string_buffer(size.value)
    if LIBC.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return [], {}
    raw = buf.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:].partition(b"\0")[2].lstrip(b"\0")   # after the exec path and its padding
    parts = [os.fsdecode(p) for p in rest.split(b"\0")]
    return parts[:argc], dict(e.split("=", 1) for e in parts[argc:] if "=" in e)


def identity(pid):
    """(start in microseconds, executable) of a running pid, or None (gone, a zombie, not readable)."""
    i = bsdinfo(pid)
    if i is None or i.status == SZOMB:
        return None
    exe = exe_of(pid)
    return (i.start_sec * 1000000 + i.start_usec, exe) if exe else None


def cpu_of(pids):
    got = {}
    if pids:
        r = subprocess.run(["ps", "-o", "pid=,%cpu=", "-p", ",".join(map(str, pids))], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                           env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"})
        for line in r.stdout.decode().splitlines():
            f = line.split()
            if len(f) == 2 and f[0].isdigit():
                got[int(f[0])] = float(f[1].replace(",", "."))
    return got


def snapshot():
    """This user's processes, one snapshot: [{pid, ppid, start (microseconds), exe (None: unreadable), argv, prefix, age}]."""
    n = LIBPROC.proc_listallpids(None, 0)
    arr = (ctypes.c_int * (max(n, 0) + 64))()
    n = LIBPROC.proc_listallpids(arr, ctypes.sizeof(arr))
    uid, now, procs = os.getuid(), time.time(), []
    for pid in arr[:max(n, 0)]:
        i = bsdinfo(pid) if pid > 0 else None
        if i is None or i.uid != uid or i.status == SZOMB:
            continue
        argv, env = args_env(pid)
        start = i.start_sec * 1000000 + i.start_usec
        procs.append({"pid": pid, "ppid": i.ppid, "start": start, "exe": exe_of(pid), "argv": argv,
                      "prefix": env.get("WINEPREFIX"), "age": int(now - start / 1e6)})
    return procs


def warm_bottle(p):
    """./revit gdrive warm: a python whose script is tools/gdrive.py and whose next argument is warm → its bottle path."""
    if not p["exe"] or not os.path.basename(p["exe"]).lower().startswith("python"):
        return None
    a = p["argv"][1:]
    while a and a[0].startswith("-"):
        if a[0] in ("-c", "-m"):
            return None   # not a script
        a = a[2:] if a[0] in ("-X", "-W") else a[1:]
    if len(a) >= 3 and a[0].endswith("/tools/gdrive.py") and a[1] == "warm":
        return a[2]
    return None


def heartbeat(path, p):
    """The warm's own heartbeat (tools/gdrive.py Beat) → the time of its last progress, or None. Its own: the pid, and
    written after this process started (a file a dead process of the same pid left is older than this one)."""
    try:
        with open(os.path.join(path, "revit-macos", "gdrive-warm-%d" % p["pid"]), encoding="utf-8") as f:
            d = json.load(f)
        if d["pid"] == p["pid"] and d["started"] >= p["start"] / 1e6 - 1:
            return float(d["progress"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def parent_gone(p, started):
    """A helper whose parent is gone: Trackpad's --parent <pid>:<lstart>, or the python MCP server with ppid 1."""
    if p["exe"] and TRACKPAD.search(p["exe"]) and "--parent" in p["argv"]:
        i = p["argv"].index("--parent")
        pid, _, when = (p["argv"][i + 1] if i + 1 < len(p["argv"]) else "").partition(":")
        try:
            want = time.mktime(time.strptime(when.strip(), "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            return False   # not ours to judge
        got = started(int(pid)) if pid.isdigit() else None
        return got is None or int(got // 1000000) != int(want)
    return PYMCP in p["argv"] and p["ppid"] == 1


def name_of(p):
    if warm_bottle(p):
        return "gdrive.py warm"
    if PYMCP in p["argv"]:
        return "python MCP server"
    a0 = p["argv"][0] if p["argv"] else ""
    return re.split(r"[\\/]", a0)[-1] if a0 else os.path.basename(p["exe"] or "")   # winedevice.exe, notepad


def classify(procs, bottles, cx, bottle=None, everything=False, started=None, now=None, mine=None):
    """The leftovers and the bottles skipped, from snapshot(). started(pid) = that process's start in microseconds, or None."""
    now = time.time() if now is None else now
    age_min = int(os.environ.get("REVIT_CLEANUP_AGE", "60"))
    stuck_min = int(os.environ.get("REVIT_GDRIVE_STUCK_AGE", "1800"))
    only = os.environ.get("REVIT_CLEANUP_ONLY", "")
    mine = mine if mine is not None else {os.getpid(), os.getppid()}
    started = started or (lambda pid: (identity(pid) or (None,))[0])
    cxs = tuple({cx.rstrip("/") + "/", os.path.realpath(cx) + "/"})   # proc_pidpath gives the real path
    roots = {bottles.rstrip("/"), os.path.realpath(bottles)}

    def bottle_of(p):   # its WINEPREFIX right under the Bottles folder → the name; elsewhere → "" (another program's)
        w = (p["prefix"] or "").rstrip("/")
        return os.path.basename(w) if os.path.dirname(w) in roots else ""

    procs = [p for p in procs if p["pid"] not in mine and p["exe"]
             and (not only or only in " ".join(p["argv"]) or only in (p["prefix"] or ""))]
    wine = [p for p in procs if p["exe"].startswith(cxs)]
    items, skipped = [], []

    def add(p, kind, reason, b):
        items.append({"pid": p["pid"], "start": p["start"], "kind": kind, "reason": reason, "bottle": b or None,
                      "name": name_of(p), "age_s": p["age"], "revit": bool(p["argv"] and REVIT.search(p["argv"][0]))})

    if everything:
        for p in wine:
            b = bottle_of(p) if p["prefix"] else None
            if bottle is None or b == bottle:
                add(p, "wine", "all", b)
    else:
        by = {}
        for p in wine:
            if p["prefix"]:   # without one its bottle is not known: left alone
                by.setdefault(bottle_of(p), []).append(p)
        for b in sorted(k for k in by if k):   # "" is Wine of another program: it neither counts nor blocks
            if bottle is not None and b != bottle:
                continue
            ps = by[b]
            if not os.path.isdir(os.path.join(bottles, b)):
                reason = "bottle_gone"
            elif any(os.path.basename(p["exe"]) == "wineserver" for p in ps):
                continue
            else:
                reason = "no_wineserver"
            if any(p["argv"] and REVIT.search(p["argv"][0]) for p in ps):
                skipped.append({"bottle": b, "why": "revit_running"})
                continue
            for p in ps:
                if p["age"] >= age_min:
                    add(p, "wine", reason, b)
    for p in procs:
        if p in wine:
            continue
        w = warm_bottle(p)
        if w is not None:
            b = os.path.basename(w.rstrip("/"))
            if bottle is not None and b != bottle:
                continue
            if everything:
                add(p, "gdrive", "all", b)
            else:
                hb = heartbeat(w, p)
                if hb is not None and now - hb >= stuck_min:
                    add(p, "gdrive", "stuck", b)
        elif bottle is None and parent_gone(p, started):
            add(p, "helper", "parent_gone", None)
    items.sort(key=lambda i: i["pid"])
    return items, skipped


def scan(bottles, cx, bottle=None, everything=False):
    procs = snapshot()
    items, skipped = classify(procs, bottles, cx, bottle, everything)
    exe = {p["pid"]: p["exe"] for p in procs}
    cpu = cpu_of([i["pid"] for i in items])
    for i in items:
        i["exe"] = exe[i["pid"]]
        i["cpu"] = cpu.get(i["pid"], 0.0)
    return items, skipped


def same(i):
    """Still the process scanned: the same start (microseconds) and executable."""
    return identity(i["pid"]) == (i["start"], i["exe"])


def wait_gone(items, secs):
    end = time.monotonic() + secs
    while True:
        left = [i for i in items if same(i)]
        if not left or time.monotonic() >= end:
            return left
        time.sleep(0.1)


def signal_all(items, sig):
    for i in items:
        if same(i):   # right before the signal: a PID taken by another process meanwhile is not hit
            try:
                os.kill(i["pid"], sig)
            except OSError:
                pass


def close(items):
    """TERM, then KILL after 3 s → the items still running."""
    signal_all(items, signal.SIGTERM)
    left = wait_gone(items, 3)
    signal_all(left, signal.SIGKILL)
    return wait_gone(left, 2)


def drop_beats(bottles, items):
    """The heartbeats of the warms that were ended (one that ended by KILL could not delete its own)."""
    for i in items:
        if i["kind"] == "gdrive" and i["bottle"]:
            try:
                os.unlink(os.path.join(bottles, i["bottle"], "revit-macos", "gdrive-warm-%d" % i["pid"]))
            except OSError:
                pass


REASONS = {"no_wineserver": "Wine stopped, the program stayed", "bottle_gone": "its bottle was deleted",
           "all": "", "parent_gone": "the program that started it is gone", "stuck": "a Google Drive folder does not answer"}


def age_text(s):
    if s >= 86400:
        return f"{s // 86400} d {s % 86400 // 3600} h"
    if s >= 3600:
        return f"{s // 3600} h {s % 3600 // 60} min"
    return f"{s // 60} min" if s >= 60 else f"{s} s"


def line(i):
    where = i["bottle"] or "no bottle"
    if i["reason"] == "bottle_gone":
        where += " (deleted)"
    why = "Revit: unsaved changes are lost" if i["revit"] else REASONS[i["reason"]]
    return f"  {i['pid']:>6}  {i['name']:<24} {where:<20} CPU {i['cpu']:.0f}%  {age_text(i['age_s']):<12} {why}".rstrip()


def targets_of(text):
    """--targets <pid>:<start>,…: the processes a person approved."""
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
    if "bottles" not in opts or "cx" not in opts:
        print("leftovers.py: --bottles and --cx are needed", file=sys.stderr)
        return 2
    try:
        want = targets_of(opts["targets"]) if "targets" in opts else None
    except ValueError as e:
        print(f"leftovers.py: --targets takes <pid>:<start>,…, not {e}", file=sys.stderr)
        return 2
    items, skipped = scan(opts["bottles"], opts["cx"], opts.get("bottle"), "all" in flags)
    if want is not None:   # only what was approved, and only while it is the same process
        items = [i for i in items if (i["pid"], i["start"]) in want]
    left = close(items) if cmd == "close" and items else []
    if cmd == "close":
        drop_beats(opts["bottles"], [i for i in items if i not in left])
    if "json" in flags:
        d = {"items": [{k: v for k, v in i.items() if k != "exe"} for i in items], "skipped": skipped}
        if cmd == "close":
            d["closed"] = [i["pid"] for i in items if i not in left]
            d["left"] = [i["pid"] for i in left]
        print(json.dumps(d))
        return 1 if left else 0
    for s in skipped:
        print(f"Skipped {s['bottle']}: Revit is among what Wine left there. To close it without saving: ./revit cleanup --all")
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
    print(f"Closed {len(items)} program(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
