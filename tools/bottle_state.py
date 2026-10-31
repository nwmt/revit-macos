#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What ./revit status --json says about one bottle beyond its files: the display and key settings and what built it.

  bottle_state.py <bottle>      prints {"retina": …, "keys": …, "built": …} as JSON
  bottle_state.py <bottle> --status S --tested T --gaps G --steps "…" --theme M --steel S --gdrive JSON
                                prints the bottle's keys of ./revit status --json: ,"support":…,"settings":…,"built":…

retina: on, compact, off; mixed when the values fit no ./revit set; "" when they cannot be read. keys: mac, windows,
"" otherwise. built: shims, engine and time of the newest install that ended ok or partial; null without one. It reads
the bottle's files only, no Wine, and writes nothing. Run with python3 -I -B.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import doctor  # noqa: E402
import runlog  # noqa: E402


def retina(s):
    if not s or s.get("mac") is None or s.get("hklm") is None:
        return ""
    on = doctor.wine_bool((s["mac"] or {}).get("retinamode"))
    dpi = doctor.effective_dpi((s.get("hkcu") or {}).get("logpixels"), (s["hklm"] or {}).get("logpixels"))
    if on is None or dpi is None:
        return ""
    return doctor.RETINA.get(("y" if on else "n", dpi), "mixed")


def keys(s):
    if not s or s.get("mac") is None:
        return ""
    mac, app = s["mac"] or {}, s.get("app") or {}
    vals = {doctor.wine_bool(app[k] if k in app else mac.get(k)) for k in doctor.KEY_VALUES}
    return {frozenset({True}): "mac", frozenset({False}): "windows"}.get(frozenset(vals), "")


def built(bottle):
    last = None
    for line in runlog._lines(runlog.runs_file(bottle)) or []:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("kind") == "install" and r.get("result") in ("ok", "partial"):
            last = r
    if last is None:
        return None
    return {k: last.get(k) or "" for k in ("shims", "engine", "time")}


def status_keys(state, a):
    """One process per bottle: ./revit status runs every few seconds."""
    steps = a.steps.split()
    try:
        drive = (json.loads(a.gdrive) or {}).get("mode", "")
    except (ValueError, AttributeError):
        drive = ""
    wanted = (("retina", "retina", state["retina"]), ("mackeys", "keys", state["keys"]), ("theme", "theme", a.theme),
              ("steel", "steel", a.steel), ("gdrive", "gdrive", drive))
    keys_ = {"support": {"status": a.status, "tested": a.tested, "gaps": a.gaps},
             "settings": {k: v for step, k, v in wanted if step in steps}, "built": state["built"]}
    return "," + json.dumps(keys_, separators=(",", ":"), ensure_ascii=False)[1:-1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("bottle")
    for o in ("status", "tested", "gaps", "steps", "theme", "steel", "gdrive"):
        p.add_argument("--" + o)
    a = p.parse_args()
    s = doctor.collect_settings(a.bottle)
    state = {"retina": retina(s), "keys": keys(s), "built": built(a.bottle)}
    sys.stdout.write(status_keys(state, a) if a.steps is not None else json.dumps(state, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
