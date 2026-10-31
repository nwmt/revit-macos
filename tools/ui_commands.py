# SPDX-License-Identifier: MIT
"""The table of Revit's commands for tools/ui_server.py: ID_... to the number WM_COMMAND needs. Revit's pyRevit extension
tools/revitmacos-ui.extension writes it into the bottle for the build that runs; nothing of it lives in this project."""
import os
import re

LIMIT = 50
ROW = re.compile(r"^(ID_[A-Za-z0-9_]+)\t([0-9]+)$")


def folder(bottle):
    return os.path.join(bottle, "drive_c", "users", "crossover", "AppData", "Local", "revit-macos")


def path(bottle, build):
    return os.path.join(folder(bottle), "ui-commands-%s.tsv" % build)


def error_path(bottle, build):
    return path(bottle, build)[:-3] + "error"


class Table:
    def __init__(self, rows):
        self.rows = rows

    def number(self, cid):
        return self.rows.get(cid)

    def search(self, words, limit=LIMIT):
        want = str(words).upper().split()
        return sorted(c for c in self.rows if all(w in c.upper() for w in want))[:limit]


def parse(text, build):
    """A Table, or None for anything that is not a whole table of this build."""
    lines = text.split("\n")
    if lines[0] != "# " + build:
        return None
    rows, seen = {}, set()
    for line in lines[1:]:
        if not line:
            continue
        m = ROW.match(line)
        if not m:
            return None
        n = int(m.group(2))
        if not 0 < n <= 0xFFFF or n in seen or m.group(1) in rows:
            return None
        rows[m.group(1)] = n
        seen.add(n)
    return Table(rows) if rows else None


def load(bottle, build):
    try:
        with open(path(bottle, build), encoding="utf-8") as f:
            return parse(f.read(), build)
    except (OSError, UnicodeDecodeError):
        return None


def status(bottle, build):
    """ready, missing or error."""
    if load(bottle, build):
        return "ready"
    if os.path.exists(path(bottle, build)) or os.path.exists(error_path(bottle, build)):
        return "error"
    return "missing"


def error_text(bottle, build):
    try:
        with open(error_path(bottle, build), encoding="utf-8", errors="replace") as f:
            return f.read()[:400]
    except OSError:
        return "The command table of this build cannot be read."
