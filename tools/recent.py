#!/usr/bin/env python3
"""What ./revit recent reads: the recent files of a bottle's Revit, from [Recent File List] in its Revit.ini.

  recent.py <bottle> <year>     JSON: {"files": [{"name", "kind", "where", "path"}]}, newest first as Revit keeps them

Revit.ini is the only file read. A recent file and its folders are never touched: G:, and Documents or Z: when they
lead into Google Drive, can wait on the network. So a file that is gone is found out when it is opened. Revit writes
Revit.ini when it quits: while it runs the list is the one from the last quit.
"""
import json
import os
import re
import sys

KINDS = ("rvt", "rfa", "rte", "rft")
HOME_WIN = "c:/users/crossover/"


def parse_ini(data):
    """The bytes of a Revit.ini → the Windows paths of [Recent File List], by File<N>, each once."""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = data.decode("utf-16", "replace")
    else:
        text = data.decode("utf-8-sig", "replace")
    found, inside = {}, False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            inside = s.lower() == "[recent file list]"
        elif inside:
            m = re.match(r"(?i)file(\d+)=(.+)$", s)
            if m:
                found.setdefault(int(m.group(1)), m.group(2).strip())
    out, seen = [], set()
    for n in sorted(found):
        k = found[n].lower()
        if k not in seen:
            seen.add(k)
            out.append(found[n])
    return out


def to_mac(bottle, win):
    """A Windows path → the same path through the bottle, as text; None: a network path, or a drive it has not."""
    m = re.match(r"^([A-Za-z]):[\\/](.*)$", win)
    if not m:
        return None
    letter, rest = m.group(1).lower(), m.group(2).split("\\")
    rest = [x for p in rest for x in p.split("/") if x]
    if letter == "c":
        return os.path.join(bottle, "drive_c", *rest)
    d = os.path.join(bottle, "dosdevices", letter + ":")
    return os.path.join(d, *rest) if os.path.lexists(d) else None


def where(win):
    """Where the file is, in words: no user name, no whole path."""
    w = win.replace("\\", "/")
    parts = [x for x in w.split("/") if x][:-1]
    if w.lower().startswith(HOME_WIN):
        rest = parts[3:]   # after C:, users, crossover
        return " › ".join(rest)
    if w[:2].lower() == "g:":
        return " › ".join(["G:"] + parts[1:])
    return parts[-1] if len(parts) > 1 else ""   # elsewhere a whole path can name the user: Z:\\Users\\…


def files(bottle, year):
    ini = os.path.join(bottle, "drive_c/users/crossover/AppData/Roaming/Autodesk/Revit", f"Autodesk Revit {year}", "Revit.ini")
    try:
        with open(ini, "rb") as f:
            data = f.read()
    except OSError:
        return []
    out = []
    for win in parse_ini(data):
        name = re.split(r"[\\/]", win)[-1]
        kind = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        if kind in KINDS:
            out.append({"name": name, "kind": kind, "where": where(win), "path": to_mac(bottle, win)})
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    print(json.dumps({"files": files(argv[0], argv[1])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
