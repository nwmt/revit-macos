# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT
# Writes the table of this Revit's commands for ./revit mcp --server ui: each ID_ name and the number WM_COMMAND needs,
# into the bottle, once per Revit build. Reads only; no output window. The list of names comes from Revit's own
# Keyboard Shortcuts data (UIFramework, not public API), the numbers from RevitCommandId. Runs on any Python of pyRevit.
import io
import os
import re
import traceback

import System
from pyrevit import HOST_APP
from Autodesk.Revit.UI import RevitCommandId

done = [False]


def folder():
    return os.path.join(os.environ["LOCALAPPDATA"], "revit-macos")


def commands():
    asm = [a for a in System.AppDomain.CurrentDomain.GetAssemblies() if a.GetName().Name == "UIFramework"]
    helper = asm[0].GetType("UIFramework.ShortcutsHelper")
    helper.GetMethod("LoadCommands").Invoke(None, None)
    items = list(helper.GetMethod("get_Commands").Invoke(None, None).Values)
    prop = items[0].GetType().GetProperty("CommandId")
    return sorted(set(n for n in (prop.GetValue(i, None) for i in items) if n and n.startswith("ID_")))


def table(build):
    rows, seen = [u"# " + build], set()
    for name in commands():
        c = RevitCommandId.LookupCommandId(name)
        if c is None:
            continue
        if c.Id in seen:
            raise ValueError("two commands have the number %d" % c.Id)
        seen.add(c.Id)
        rows.append(u"%s\t%d" % (name, c.Id))
    if len(rows) < 2:
        raise ValueError("no commands found")
    return u"\n".join(rows) + u"\n"


def write(path, text):
    with io.open(path + ".new", "w", encoding="utf-8", newline=u"\n") as f:
        f.write(text)
    if os.path.exists(path):
        os.remove(path)
    os.rename(path + ".new", path)


def journal_build(app):
    """The build as the journal of this run gives it: tools/ui_journal.py reads the same line."""
    with io.open(app.RecordingJournalFilename, encoding="latin-1") as f:
        for _ in range(40):
            m = re.match(r"^' Build: (\S+?)(?:\(x\d+\))?\s*$", f.readline())
            if m:
                return m.group(1)
    raise ValueError("no build in the journal")


def run(app):
    build = journal_build(app)
    d = folder()
    if not os.path.isdir(d):
        os.makedirs(d)
    path = os.path.join(d, "ui-commands-%s.tsv" % build)
    if os.path.exists(path):
        return
    try:
        write(path, table(build))
        if os.path.exists(path[:-3] + "error"):
            os.remove(path[:-3] + "error")
    except Exception:
        write(path[:-3] + "error", u"%s" % traceback.format_exc())


def tick(sender, args):
    if done[0]:
        return
    done[0] = True
    try:
        run(HOST_APP.uiapp.Application)
    except Exception:
        d = folder()
        if not os.path.isdir(d):
            os.makedirs(d)
        write(os.path.join(d, "ui-commands.error"), u"%s" % traceback.format_exc())


HOST_APP.uiapp.Idling += tick
