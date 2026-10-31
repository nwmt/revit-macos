# SPDX-License-Identifier: MIT
"""Revit's journal for tools/ui_server.py: which file belongs to this run, its build, and the Jrn.Command lines that
appear in it. Read as bytes: only the ASCII fields matter, and the end of a file that is still growing is left for the
next read."""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bottleread  # noqa: E402

Rec = collections.namedtuple("Rec", "label command")
COMMAND = re.compile(rb'^\s*Jrn\.Command\s+"([^"]*)"\s*,\s*".*,\s*([A-Za-z0-9_%]+)"\s*$')
BUILD = re.compile(rb"^' Build: (\S+?)(?:\(x\d+\))?\s*$")
BUILD_LINES = 40


def find(bottle, year, started):
    """The journal of the run that started at this time, or None: the newest one, not older than the run."""
    path = bottleread.newest_journal(bottle, year)
    try:
        return path if path and os.stat(path).st_mtime >= started else None
    except OSError:
        return None


def build(path):
    """The build in the journal's head, without (x64), or None."""
    try:
        with open(path, "rb") as f:
            for _ in range(BUILD_LINES):
                m = BUILD.match(f.readline())
                if m:
                    return m.group(1).decode("ascii", "replace")
    except OSError:
        pass
    return None


class Reader:
    """New whole Jrn.Command lines of one file. lost: the file is gone, shorter, or another file now has its name."""

    def __init__(self, path, offset=0, identity=None):
        self.path, self.offset, self.identity = path, offset, tuple(identity) if identity else None
        self.lost = False

    def read(self):
        if self.lost:
            return []
        try:
            with open(self.path, "rb") as f:
                st = os.fstat(f.fileno())
                now = (st.st_dev, st.st_ino)
                if self.identity is None:
                    self.identity = now
                if now != self.identity or st.st_size < self.offset:
                    self.lost = True
                    return []
                f.seek(self.offset)
                data = f.read()
        except OSError:
            self.lost = True
            return []
        end = data.rfind(b"\n") + 1
        self.offset += end
        recs = []
        for line in data[:end].split(b"\n"):
            m = COMMAND.match(line)
            if m:
                recs.append(Rec(m.group(1).decode("ascii", "replace"), m.group(2).decode("ascii", "replace")))
        return recs
