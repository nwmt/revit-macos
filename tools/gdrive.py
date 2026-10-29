#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The G: drive of a bottle: Google Drive for desktop, with the folders it has on Windows (G:\\My Drive,
G:\\Shared drives, G:\\Other computers) and, if asked, second names for them (the ru preset:
the names a Russian Windows gives them).

  gdrive.py names <value>        check a names setting; prints the folders and their second names as JSON (code 2: bad)
  gdrive.py state <bottle>       prints the state as JSON: mode, mapping, accounts, names, settings
  gdrive.py advice <bottle> <year>   prints the level (ok, info, warn) and one line of advice
  gdrive.py sanitize <bottle>    copies stdin to stdout with Google Drive paths and email addresses hidden

The bottle keeps it in drive_g/ (a marker file and one link per name) and dosdevices/g: -> ../drive_g; the setting
is in drive_c/Program Files/revit-macos/gdrive (mode=auto|off|<email>, names=<value>). Nothing here writes to Google
Drive. Output never carries an account's email or the path of its folder. Run with python3 -I.
"""
import json
import os
import re
import stat
import sys
import unicodedata

ROLES = ("My Drive", "Shared drives", "Other computers")
PRESETS = {"en": {}, "ru": {"My Drive": ["\u041c\u043e\u0439 \u0434\u0438\u0441\u043a"], "Shared drives": ["\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438"],
                            "Other computers": ["\u041a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b"]}}
MARK = ".revit-macos-gdrive"
SETTINGS = ("drive_c", "Program Files", "revit-macos", "gdrive")
BAD_CHARS = set('\\/:*?"<>|;=@')
RESERVED = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {f"lpt{i}" for i in range(1, 10)}
EMAIL = re.compile(r"[^\s@/\\:;=<>\"']+@[^\s@/\\:;=<>\"']+\.[A-Za-z]{2,}")


class NamesError(Exception):
    def __init__(self, pair, reason):
        super().__init__(f"name {pair}: {reason}")
        self.pair, self.reason = pair, reason


def key(name):
    return unicodedata.normalize("NFC", name).casefold()


def check_name(name, pair):
    if not name:
        raise NamesError(pair, "empty")
    if any(c in BAD_CHARS or unicodedata.category(c).startswith("C") for c in name):
        raise NamesError(pair, "a character Windows or this setting cannot take")
    if name[-1] in ". ":
        raise NamesError(pair, "ends with a dot or a space")
    if name.split(".")[0].casefold() in RESERVED or name.casefold() == MARK.casefold():
        raise NamesError(pair, "a reserved name")


def parse_names(value):
    """'' | 'en' | 'ru' | 'ru;Role=Name;\u2026' \u2192 {role: [second names]}. Raises NamesError (pair number, reason)."""
    names = {r: [] for r in ROLES}
    own = {}
    for i, item in enumerate([x for x in (value or "").split(";")], 1):
        if item == "" and i == 1 and value in ("", None):
            break
        if "=" not in item:
            if i != 1:
                raise NamesError(i, "a preset comes first")
            if item not in PRESETS:
                raise NamesError(i, "not a preset (en, ru)")
            for r, ns in PRESETS[item].items():
                names[r] = list(ns)
            continue
        role, name = item.split("=", 1)
        if role not in ROLES:
            raise NamesError(i, "not a Google Drive folder (My Drive, Shared drives, Other computers)")
        name = unicodedata.normalize("NFC", name)
        check_name(name, i)
        own.setdefault(role, []).append((i, name))
    for role, pairs in own.items():
        names[role] = [n for _, n in pairs]
    seen = {key(r): 0 for r in ROLES}
    order = {n: i for pairs in own.values() for i, n in pairs}
    for role in ROLES:
        for n in names[role]:
            k = key(n)
            if k in seen:
                raise NamesError(order.get(n, 1), "the same name as another folder")
            seen[k] = order.get(n, 1)
    return names


def cloud():
    return os.path.join(os.path.expanduser("~"), "Library", "CloudStorage")


def accounts():
    """The Google Drive accounts on this Mac: real folders GoogleDrive-*, sorted."""
    out = []
    try:
        entries = sorted(os.scandir(cloud()), key=lambda e: e.name)
    except OSError:
        return out
    for e in entries:
        if e.name.startswith("GoogleDrive-") and e.is_dir(follow_symlinks=False):
            out.append(e.path)
    return out


def account_of(email):
    p = os.path.join(cloud(), "GoogleDrive-" + email)
    return p if os.path.isdir(p) and not os.path.islink(p) else None


def read_settings(b):
    p = os.path.join(b, *SETTINGS)
    try:
        st = os.lstat(p)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode):
        return None
    out = {"mode": "auto", "names": "en"}
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("=")
            if k in out:
                out[k] = v
    return out


def owned_dir(p, may_be_empty=False):
    """A real folder with our marker (a regular file) and nothing but links; or, if may_be_empty, an empty real folder."""
    try:
        if not stat.S_ISDIR(os.lstat(p).st_mode):
            return False
        entries = list(os.scandir(p))
    except OSError:
        return False
    if not entries:
        return may_be_empty
    marked = False
    for e in entries:
        if e.name == MARK:
            if not e.is_file(follow_symlinks=False):
                return False
            marked = True
        elif not e.is_symlink():
            return False
    return marked


def mapped(b):
    """What G: in the bottle points at now: ('none'|'ours'|'foreign', {name: target})."""
    gl = os.path.join(b, "dosdevices", "g:")
    dg = os.path.join(b, "drive_g")
    has_g = os.path.lexists(gl)
    if has_g and (not os.path.islink(gl) or os.readlink(gl) != "../drive_g"):
        return "foreign", {}
    if os.path.lexists(dg) and not owned_dir(dg):
        return "foreign", {}
    if not has_g:
        return "none", {}
    links = {}
    if os.path.lexists(dg):
        for e in os.scandir(dg):
            if e.name != MARK:
                links[e.name] = os.readlink(e.path)
    return "ours", links


def wanted(b, s=None):
    """The account folder the setting asks for (None: none can be chosen) and the names {role: [names]}."""
    s = s or read_settings(b) or {"mode": "auto", "names": "en"}
    try:
        names = parse_names(s["names"])
    except NamesError:
        names = parse_names("en")
    mode = s["mode"]
    if mode == "off":
        return None, names
    if mode == "auto":
        acc = accounts()
        return (acc[0] if len(acc) == 1 else None), names
    return account_of(mode), names


def state(b):
    s = read_settings(b)
    mode = (s or {}).get("mode", "auto")
    acc = accounts()
    out = {"mode": mode if mode in ("auto", "off") else "account",
           "mapping": "none", "accounts": ("zero", "one", "several")[min(len(acc), 2)],
           "names": 0, "settings": s is not None}
    kind, links = mapped(b)
    want_acc, names = wanted(b, s)
    out["names"] = sum(len(v) for v in names.values())
    if kind != "ours":
        out["mapping"] = kind
        return out
    if not links:
        out["mapping"] = "stale"
        return out
    roots = {os.path.dirname(t) for t in links.values()}
    root = roots.pop() if len(roots) == 1 else None
    if root is None:
        out["mapping"] = "stale"
    elif not os.path.isdir(root):
        out["mapping"] = "account-missing"
    else:
        expect = {r: r for r in ROLES}
        for r, ns in names.items():
            for n in ns:
                expect[n] = r
        now = {n: os.path.basename(t) for n, t in links.items()}
        same_names = now == expect
        if mode == "auto" and want_acc is None:
            same_acc = True   # no account to choose: the one G: has is as good as any
        else:
            same_acc = want_acc is not None and os.path.realpath(root) == os.path.realpath(want_acc)
        out["mapping"] = "ok" if same_names and same_acc and mode != "off" else "stale"
    return out


def advice(s, year):
    """(level, line) for a state, the same for the step, new-bottle.sh and doctor. No email, no paths."""
    set_ = f"./revit set {year}"
    if s["mapping"] == "foreign":
        return "warn", "G: is used by something else in this bottle: G: from Google Drive is not set up"
    if s["mode"] == "off":
        if s["mapping"] == "none":
            return "info", "G: off"
        return "warn", f"G: is still set up although it is off: {set_} gdrive=again"
    again = f"{set_} gdrive=again" if s["settings"] else f"{set_} gdrive=auto"
    if s["mapping"] == "ok":
        line = "G: \u2192 Google Drive" + (f" ({s['names']} more folder names)" if s["names"] else "")
        if s["mode"] == "auto" and s["accounts"] == "several":
            return "warn", line + f"; several Google Drive accounts on this Mac: {set_} gdrive=<email> picks one"
        return "ok", line
    if s["mapping"] == "account-missing":
        if s["mode"] == "auto" and s["accounts"] == "several":
            return "warn", f"G: points to a Google Drive account that is gone; several are here: {set_} gdrive=<email>"
        return "warn", f"G: points to a Google Drive account that is gone: {again}"
    if s["mode"] == "account":
        if s["accounts"] == "zero" or s["mapping"] != "stale" and not s["settings"]:
            return "warn", "the chosen Google Drive account is not on this Mac: G: is not set up"
        return "warn", f"G: is not set up: {set_} gdrive=again"
    if s["accounts"] == "zero":
        return "info", "Google Drive not found: no G: drive"
    if s["accounts"] == "several":
        return "warn", f"Several Google Drive accounts: {set_} gdrive=<email>"
    return "warn", f"G: is not set up: {again}"


def sanitize(text, b=None):
    """Account folders \u2192 GoogleDrive-<account>, any email address \u2192 <account>."""
    for a in accounts():
        text = text.replace(a, os.path.join("\u2026", "GoogleDrive-<account>"))
    text = re.sub(r"GoogleDrive-[^/\s]+", "GoogleDrive-<account>", text)
    return EMAIL.sub("<account>", text)


def main(argv):
    if len(argv) >= 2 and argv[0] == "names":
        try:
            print(json.dumps(parse_names(argv[1]), ensure_ascii=False))
        except NamesError as e:
            print(f"gdrive_names: {e}", file=sys.stderr)
            return 2
        return 0
    if len(argv) == 2 and argv[0] == "state":
        print(json.dumps(state(argv[1])))
        return 0
    if len(argv) == 3 and argv[0] == "advice":
        lvl, line = advice(state(argv[1]), argv[2])
        print(f"{lvl}\t{line}")
        return 0
    if len(argv) == 2 and argv[0] == "sanitize":
        for line in sys.stdin:
            sys.stdout.write(sanitize(line, argv[1]))
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
