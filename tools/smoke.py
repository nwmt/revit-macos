#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Journals for ./revit test and the verdict on the journal Revit writes back while it plays one.

  smoke.py journal <scenario> --year Y [--template WINPATH] --out FILE
      the journal of a scenario (start, core, reopen) from scripts/smoke/<scenario>.txt; CRLF, Windows-1252
  smoke.py template <clone_dir> <year>
      the project template for core: "WINPATH<TAB>revit.ini|table"; exit 1 if none exists in the bottle
  smoke.py signin <bottle_dir> <year>
      {"signed_in", "journal_age_days", "license_days_left"} from Revit's newest journal in the bottle
  smoke.py verdict <scenario> --journal FILE --replayed FILE|'' --since MARKER [--outputs DIR]
                   [--watchdog none|start|stall|total] [--signin-seen] [--no-start] [--crash-log FILE]
      {"verdict": "pass|fail|person", "kind", "reason", "fix", "dialog_id", "build", "release", "stopped_at",
       "exit_line", "t_start_idle", "t_total", "longest_gap", "outputs"} for one run (see decide())
  smoke.py lint [FILE...]
      checks the journal templates (scripts/smoke/*.txt unless files are given); exit 1 on a problem

--journal is the journal we generated, --replayed the journal.NNNN.txt Revit wrote while playing it ('' if none),
--since the file touched just before Revit started, --outputs the Mac path of C:\\revit-smoke\\out. The runner says
what its watchdog did and whether it saw a sign-in process (--signin-seen) or no Revit at all (--no-start).

Revit's journals hold the Autodesk user name and file paths, so nothing here prints a line of one: only dialog ids,
the build, the release, line numbers and times. Only journal writes a file (--out). Run with python3 -I -B.
"""
import datetime
import glob
import json
import ntpath
import os
import re
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bottleread import ini_get, newest_journal, read_ini, read_lines  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATES = os.path.join(ROOT, "scripts", "smoke")
SCENARIOS = ("start", "core", "reopen")
OUTPUTS = {"start": (), "core": ("smoke.rvt",), "reopen": ("smoke2.rvt",)}
# Jrn.Directive "Version": "<year>.000" and the journal format of that year (as in Revit's and RFO's journals)
FORMAT = {2020: "2.164", 2023: "2.169", 2024: "2.169", 2025: "2.169", 2026: "2.179", 2027: "2.179"}
# when Revit.ini names no template that exists: the one each year's install puts under Templates
TEMPLATE = {2020: "US Imperial\\default.rte", 2023: "English\\DefaultMetric.rte"}
TEMPLATE_OTHER = "English\\Default-Multi-Discipline_Metric.rte"
REVIT_INI = "drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit {year}/Revit.ini"
PROVENANCE = "' Written by hand for ./revit test; no recorded or third-party journal text."
PLACEHOLDERS = ("VERSION", "FORMAT", "TEMPLATE", "TEMPLATE_NAME")
OLE = bytes.fromhex("d0cf11e0a1b11ae1")   # a compound file: what a .rvt starts with

STRONG = ("unrecoverable error", "Exception occurred", "captureTryCrash", "Assertion failed")
WINE_CRASH = re.compile(r"wine: Unhandled (?:page fault|exception)")
# sign-in, licensing, EULA, trial: in a dialog id (TaskDialog_..., Dialog_...) and in a dialog's text
PERSON_ID = re.compile(r"sign_?(?:in|out)|log_?(?:in|out|on)|licen[cs]|eula|trial|adsso|identity|entitle|subscription",
                       re.I)
PERSON_TEXT = re.compile(r"\bsign(?:ed|ing)?[ -]?(?:in|out)\b|\blog(?:ged|ging)?[ -]?(?:in|out|on)\b|\blicen[cs]|"
                         r"\beula\b|\btrial\b|\bsubscription\b|\bentitle|\bautodesk (?:account|id)\b|"
                         r"\banother (?:device|computer)\b", re.I)
CRASHY = re.compile(r"unrecoverable|fatal error", re.I)   # the dialog that reports a crash, not its cause
STAMP = re.compile(r"^\s*'[A-Z] (\d{1,2})-([^\W\d_]{3,4})-(\d{4}) (\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?;")
MONTHS = {m: i for i, m in enumerate(("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov",
                                      "dec"), 1)}
EPOCH = datetime.datetime(2000, 1, 1)
STOPPED = re.compile(r"stopped at line (\d+) journal file playback")   # 2024+ put JOURNAL_MARKER_TAIL_END: before it
PLAYBACK = re.compile(r'started journal file playback of "([^"]*)"')
EXPIRE = re.compile(r"license will expire in (\d+) days", re.I)

FIX_SIGNIN = "Open Revit from ~/Applications, sign in, quit Revit, then run the test again."
FIX_CROSSOVER = "Open CrossOver and answer what it asks (for example about the trial), then run the test again."


def options(args, values, flags=()):
    """args → (positional, {name: value}): --name VALUE for names in values, --name alone for flags."""
    pos, out, i = [], {}, 0
    while i < len(args):
        a = args[i]
        if a in values and i + 1 < len(args):
            out[a[2:]] = args[i + 1]
            i += 2
        elif a in flags:
            out[a[2:]] = True
            i += 1
        elif a.startswith("--") and a != "--":
            sys.exit(f"{a}: unknown option or missing value\n\n{__doc__}")
        else:
            pos.append(a)
            i += 1
    return pos, out


def year_arg(s):
    if not re.fullmatch(r"20\d\d", s or ""):
        sys.exit(f"not a Revit year: {s}")
    return int(s)


# --- journal ---

def make_journal(scenario, year, template=None):
    """The text of a scenario's journal for one Revit year; SystemExit with a reason if it cannot be made."""
    if scenario not in SCENARIOS:
        raise SystemExit(f"unknown scenario: {scenario} (one of {', '.join(SCENARIOS)})")
    if year not in FORMAT:
        raise SystemExit(f"no journal format known for Revit {year}")
    with open(os.path.join(TEMPLATES, scenario + ".txt"), encoding="ascii") as f:
        text = f.read()
    subs = {"VERSION": f"{year}.000", "FORMAT": FORMAT[year]}
    if "{{TEMPLATE" in text:
        if not template:
            raise SystemExit(f"the {scenario} journal needs --template")
        if not re.fullmatch(r'[A-Za-z]:\\[^"\r\n]+\.rte', template, re.I):
            raise SystemExit("--template: the Windows path of an .rte file")
        subs["TEMPLATE"], subs["TEMPLATE_NAME"] = template, ntpath.basename(template)
    text = re.sub(r"\{\{(\w+)\}\}", lambda m: subs.get(m.group(1), m.group(0)), text)
    if "{{" in text:
        raise SystemExit(f"{scenario}.txt has a placeholder smoke.py does not fill in")
    return "".join(line + "\r\n" for line in text.splitlines())


def write_journal(text, out):
    try:
        data = text.encode("cp1252")   # Revit reads and writes journals in the ANSI code page
    except UnicodeEncodeError:
        raise SystemExit("the template path has characters a journal cannot hold")
    with open(out, "wb") as f:
        f.write(data)


def exit_line(path):
    """Line number (from 1) of the ID_APP_EXIT command in a journal, or None."""
    n_exit = None
    for n, line in enumerate(read_lines(path), 1):
        if line.lstrip().startswith("Jrn.Command") and "ID_APP_EXIT" in line:
            n_exit = n
    return n_exit


# --- template ---

def win_file(bottle, winpath):
    """The Mac path of an existing file C:\\... in a bottle (names matched without case, as Wine does), or None."""
    if not re.match(r"[Cc]:\\", winpath):
        return None
    cur = os.path.join(bottle, "drive_c")
    for part in [p for p in winpath[3:].split("\\") if p]:
        if part in (".", ".."):
            return None
        nxt = os.path.join(cur, part)
        if not os.path.lexists(nxt):
            try:
                same = [n for n in os.listdir(cur) if n.lower() == part.lower()]
            except OSError:
                return None
            if not same:
                return None
            nxt = os.path.join(cur, same[0])
        cur = nxt
    return cur if os.path.isfile(cur) else None


def ini_templates(value, year):
    """The paths in a DefaultTemplate value: "Label=C:\\...rte, Label=C:\\...rte", in order."""
    out = []
    for part in value.split(","):
        m = re.search(r"([A-Za-z]:\\.*|\$AllUsersAppData\\.*)$", part.strip(), re.I)
        if not m:
            continue
        p = m.group(1).strip()
        if p.lower().startswith("$allusersappdata\\"):
            p = f"C:\\ProgramData\\Autodesk\\RVT {year}\\" + p.split("\\", 1)[1]
        out.append(p)
    return out


def journal_safe(path):
    """A path that can go into a journal string: an .rte file, no quote, Windows-1252 letters only."""
    if '"' in path or not path.lower().endswith(".rte"):
        return False
    try:
        path.encode("cp1252")
    except UnicodeEncodeError:
        return False
    return True


def find_template(bottle, year):
    """(WINPATH, "revit.ini"|"table") of the first template that exists in the bottle, or (None, None). Revit.ini:
    DefaultTemplate in [Directories<Select>] ([Language] Select, ENU if unset)."""
    ini = read_ini(os.path.join(bottle, REVIT_INI.format(year=year)))
    lang = (ini_get(ini, "Language", "Select") or "ENU").strip()
    for p in ini_templates(ini_get(ini, "Directories" + lang, "DefaultTemplate") or "", year):
        if journal_safe(p) and win_file(bottle, p):
            return p, "revit.ini"
    p = f"C:\\ProgramData\\Autodesk\\RVT {year}\\Templates\\" + TEMPLATE.get(year, TEMPLATE_OTHER)
    if win_file(bottle, p):
        return p, "table"
    return None, None


# --- signin ---

def signin(bottle, year):
    """What Revit's newest journal in the bottle says about the sign-in. Keeps no line and no value but these."""
    out = {"signed_in": False, "journal_age_days": None, "license_days_left": None}
    path = newest_journal(bottle, year)
    if not path:
        return out
    try:
        out["journal_age_days"] = max(0, int((time.time() - os.path.getmtime(path)) // 86400))
    except OSError:
        return out
    for line in read_lines(path):
        if "License mode: User" in line:
            out["signed_in"] = True
        m = EXPIRE.search(line)
        if m:
            out["license_days_left"] = int(m.group(1))
    return out


# --- verdict ---

def stamp(line):
    """Seconds of a journal timestamp line ('C 16-Oct-2026 11:11:28.123;), or None. Only differences are used: a month
    name that is not English counts as January."""
    m = STAMP.match(line)
    if not m:
        return None
    d, mon, y, hh, mm, ss, ms = m.groups()
    try:
        t = datetime.datetime(int(y), MONTHS.get(mon.lower()[:3], 1), int(d), int(hh), int(mm), int(ss))
    except ValueError:
        return None
    return (t - EPOCH).total_seconds() + int((ms or "0").ljust(3, "0")) / 1000.0


def scan(path):
    """One pass over a journal Revit wrote: the markers the verdict needs. Keeps flags, ids and times, never a line."""
    j = {"build": None, "release": None, "branch": None, "playback": None, "stopped_at": None, "finished": False,
         "license_mode": False, "license_update": False, "manage_open": False, "strong": [], "first": None,
         "last": None, "idle": None, "gap": None}
    tasks, modals = [], []   # dialogs not closed yet: [id, needs a person, reports a crash]
    prev = None
    for n, line in enumerate(read_lines(path), 1):
        if n <= 40:
            m = re.match(r"' (Build|Release|Branch): (\S.*?)\s*$", line)
            if m:
                j[m.group(1).lower()] = m.group(2)
        t = stamp(line)
        if t is not None:
            if j["first"] is None:
                j["first"] = t
            if prev is not None and (j["gap"] is None or t - prev > j["gap"]):
                j["gap"] = t - prev
            prev = j["last"] = t
            if j["idle"] is None and "appPriv idle" in line:
                j["idle"] = t
        low = line.lower()
        for s in STRONG:
            if s.lower() in low and s not in j["strong"]:
                j["strong"].append(s)
        m = PLAYBACK.search(line)
        if m:
            j["playback"] = ntpath.basename(m.group(1)).lower()
        m = STOPPED.search(line)
        if m:
            j["stopped_at"] = int(m.group(1))
        if "finished recording journal file" in line:
            j["finished"] = True
        if "manage licensing" in line:
            j["manage_open"] = True
        if "License Update" in line or "LicenseUpd(" in line:
            j["license_update"], j["manage_open"] = True, False
        if "License mode:" in line:
            j["license_mode"], j["manage_open"] = True, False
        # TaskDialog "<text>" / 'Id : TaskDialog_<name> / ... / Jrn.Data "TaskDialogResult" once it is answered
        k = line.find('TaskDialog "')
        if k >= 0 and "TaskDialogResult" not in line:
            text = line[k + 12:]
            tasks.append([None, bool(PERSON_TEXT.search(text)), bool(CRASHY.search(text))])
        m = re.match(r"\s*'Id : (\S+)", line)
        if m and tasks and tasks[-1][0] is None:
            tasks[-1][0] = m.group(1)
            tasks[-1][1] = tasks[-1][1] or bool(PERSON_ID.search(m.group(1)))
            tasks[-1][2] = tasks[-1][2] or bool(CRASHY.search(m.group(1)))
        if "TaskDialogResult" in line and tasks:
            tasks.pop()
        # a Revit dialog: ADialog::doModal start ... stop; its id shows only when the journal acts on it
        if "ADialog::doModal start" in line:
            modals.append([None, False, False])
        elif "ADialog::doModal stop" in line and modals:
            modals.pop()
        elif modals and modals[-1][0] is None:
            m = re.search(r"\b(Dialog_\w+)", line)
            if m:
                modals[-1][0], modals[-1][1] = m.group(1), bool(PERSON_ID.search(m.group(1)))
    j["dialogs"] = [tuple(d) for d in tasks + modals]
    j["modal_open"] = len(modals)
    if not j["release"] and (j["branch"] or "").startswith("RELEASE_"):
        j["release"] = j["branch"][8:]   # 2020 has no Release line, only Branch: RELEASE_2020
    return j


def output_check(scenario, out_dir, since_ns):
    """{name: {"size", "problem"}} for the files a scenario writes; problem: None, missing, stale, empty, not a Revit
    file."""
    res = {}
    for name in OUTPUTS[scenario]:
        p = os.path.join(out_dir, name) if out_dir else None
        try:
            st = os.stat(p) if p else None
        except OSError:
            st = None
        if st is None or not os.path.isfile(p):
            res[name] = {"size": None, "problem": "missing"}
            continue
        problem = None
        if st.st_mtime_ns < since_ns:
            problem = "stale"
        elif st.st_size == 0:
            problem = "empty"
        else:
            with open(p, "rb") as f:
                if f.read(len(OLE)) != OLE:
                    problem = "not a Revit file"
        res[name] = {"size": st.st_size, "problem": problem}
    return res


def decide(j, exit_at, outputs, watchdog="none", signin_seen=False, no_start=False, crashed_wine=False, expect=None):
    """(verdict, kind, reason, fix, dialog_id). j: scan() of the replayed journal, None if Revit wrote none for this
    run; exit_at: the ID_APP_EXIT line of the played journal; outputs: output_check(); expect: the played journal's
    file name. Order: a person must act, then pass, then fail with the first reason that applies."""
    stuck = watchdog not in (None, "", "none")
    ended = bool(j and j["finished"] and j["stopped_at"] is not None and exit_at and j["stopped_at"] >= exit_at)
    dialogs = [d for d in (j["dialogs"] if j else []) if not d[2]]   # leave out the dialog that reports a crash
    licensed = bool(j and (j["license_update"] or j["license_mode"]))

    def person(kind, reason, fix, did=None):
        return "person", kind, reason, fix, did

    def fail(kind, reason, did=None):
        return "fail", kind, reason, None, did

    if no_start:
        return person("no_start", "Revit did not start: CrossOver stopped it or showed a question", FIX_CROSSOVER)
    if signin_seen and not licensed:
        return person("signin", "Revit asked to sign in", FIX_SIGNIN)
    if not ended:
        for did, needs, _ in reversed(dialogs):
            if needs:
                return person("license_dialog", "Revit stopped at a sign-in or licensing dialog", FIX_SIGNIN, did)
        if j and j["manage_open"]:
            return person("license_blocked", "Revit's licensing did not finish", FIX_SIGNIN)

    problems = [f"{n}: {o['problem']}" for n, o in sorted(outputs.items()) if o["problem"]]
    if (ended and not stuck and j["license_mode"] and not j["strong"] and not j["dialogs"] and not problems
            and (expect is None or j["playback"] == expect.lower())):
        return "pass", "pass", "Revit played the journal to its end and quit normally", None, None

    did = dialogs[-1][0] if dialogs else None
    if dialogs and not ended:
        crash = f", then crashed ({j['strong'][0]})" if j["strong"] else ""
        return fail("dialog", f"Revit stopped at a dialog ({did or 'its id is not in the journal'}){crash}", did)
    if j and j["strong"]:
        return fail("crash", f"Revit crashed ({j['strong'][0]})")
    if watchdog == "start":
        return fail("hung_start", "Revit hung while starting")
    if watchdog == "stall":
        return fail("hung", "Revit hung: its journal stopped growing")
    if stuck:
        return fail("timeout", "Revit did not finish in time")
    wine = " (wine reported an unhandled exception)" if crashed_wine else ""
    if j is None:
        return fail("no_journal", "Revit wrote no journal for this run" + wine)
    if j["playback"] is None:
        return fail("incomplete", "Revit did not start playing the journal" + wine)
    if expect is not None and j["playback"] != expect.lower():
        return fail("other_journal", "the new journal is not the replay of this scenario")
    if not j["finished"]:
        return fail("crash", "Revit ended without closing its journal" + wine)
    if not ended:
        at = j["stopped_at"]
        return fail("incomplete", f"the replay stopped at line {at}; the exit is on line {exit_at}" if at
                    else "the journal does not say where the replay stopped")
    if not j["license_mode"]:
        return fail("no_license", "Revit did not report a license")
    if j["dialogs"]:
        return fail("dialog", f"Revit left a dialog open ({did or 'its id is not in the journal'})", did)
    return fail("no_output", "; ".join(problems))


def verdict(scenario, journal, replayed, since, out_dir=None, watchdog="none", signin_seen=False, no_start=False,
            crash_log=None):
    """The verdict of one run as a dict (the JSON that smoke.py verdict prints). Times in seconds from the journal's
    timestamps: t_start_idle from its first one to 'appPriv idle', t_total from first to last, longest_gap between two
    in a row (a long gap alone is no failure: the runner's watchdog decides what hung)."""
    exit_at = exit_line(journal)
    if exit_at is None:
        raise SystemExit(f"no ID_APP_EXIT command in {os.path.basename(journal)}")
    since_ns = os.stat(since).st_mtime_ns
    j = None
    if replayed and replayed not in ("-", "--") and os.path.isfile(replayed) \
            and os.stat(replayed).st_mtime_ns >= since_ns:
        j = scan(replayed)
    wine = False
    if crash_log and os.path.isfile(crash_log):
        wine = any(WINE_CRASH.search(line) for line in read_lines(crash_log))
    outputs = output_check(scenario, out_dir, since_ns)
    v, kind, reason, fix, did = decide(j, exit_at, outputs, watchdog, signin_seen, no_start, wine,
                                       os.path.basename(journal))

    def secs(a, b):
        return round(b - a, 1) if a is not None and b is not None else None

    return {"verdict": v, "kind": kind, "reason": reason, "fix": fix, "dialog_id": did,
            "build": j["build"] if j else None, "release": j["release"] if j else None,
            "stopped_at": j["stopped_at"] if j else None, "exit_line": exit_at,
            "t_start_idle": secs(j["first"], j["idle"]) if j else None,
            "t_total": secs(j["first"], j["last"]) if j else None,
            "longest_gap": round(j["gap"], 1) if j and j["gap"] is not None else None, "outputs": outputs}


# --- lint ---

LINT = [
    (re.compile(r"PerformAutomaticActionInErrorDialog|PermissiveJournal", re.I), "a directive that answers dialogs"),
    (re.compile(r'Jrn\.Directive\s+"Username"', re.I), "a Username directive"),
    (re.compile(r"^\s*'.*\d+:<"), "a line Revit writes when it records a journal (' 0:<)"),
    (re.compile(r"^\s*'[A-Z] \d{1,2}-\w{3,4}-\d{4} "), "a timestamp line of a recorded journal ('C dd-...)"),
    (re.compile(r"^'\s*(?:Build|Release|Branch):"), "a header line of a recorded journal"),
    (re.compile(r"\s_\s*$"), "a line continuation, as in a recorded journal"),
    (re.compile(r"(?<![A-Za-z])[A-Za-z]:\\(?!revit-smoke\\)", re.I), "an absolute path outside C:\\revit-smoke\\"),
    (re.compile(r"\\\\[A-Za-z0-9]|/Users/|%\w+%|\$AllUsersAppData", re.I),
     "a path or variable outside C:\\revit-smoke\\"),
]


def lint(paths):
    """Problems in journal templates as "file:line: problem" strings."""
    out = []
    for path in paths:
        name = os.path.basename(path)
        with open(path, "rb") as f:
            raw = f.read()
        text = raw.decode("utf-8", errors="replace")
        lines = text.splitlines()
        if not lines or lines[0] != PROVENANCE:
            out.append(f"{name}:1: the first line is not the provenance comment")
        code = []
        for n, line in enumerate(lines, 1):
            if re.search(r"[^\x20-\x7e\t]", line):
                out.append(f"{name}:{n}: a character outside printable ASCII")
            for rx, what in LINT:
                if rx.search(line):
                    out.append(f"{name}:{n}: {what}")
            for ph in re.findall(r"\{\{(\w*)\}\}", line):
                if ph not in PLACEHOLDERS:
                    out.append(f"{name}:{n}: unknown placeholder {{{{{ph}}}}}")
            s = line.strip()
            if not s or s.startswith("'"):
                continue
            code.append((n, s))
            if not (s in ("Dim Jrn", "Set Jrn = CrsJournalScript") or re.match(r"Jrn\.[A-Za-z]+\s", s)):
                out.append(f"{name}:{n}: not a Jrn line (no VBScript beyond Dim/Set Jrn)")
            if PERSON_ID.search(s):
                out.append(f"{name}:{n}: a sign-in, licensing or EULA command")
        if not any(s == 'Jrn.Directive "Version", "{{VERSION}}", "{{FORMAT}}"' for _, s in code):
            out.append(f'{name}: no Jrn.Directive "Version", "{{{{VERSION}}}}", "{{{{FORMAT}}}}"')
        exits = [n for n, s in code if "ID_APP_EXIT" in s]
        if len(exits) != 1 or not code or exits[0] != code[-1][0] or not code[-1][1].startswith("Jrn.Command "):
            out.append(f"{name}: the last command must be the only ID_APP_EXIT")
    return out


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else ""
    if cmd == "journal":
        pos, o = options(a[1:], ("--year", "--template", "--out"))
        if len(pos) != 1 or "out" not in o:
            sys.exit(__doc__)
        write_journal(make_journal(pos[0], year_arg(o.get("year")), o.get("template")), o["out"])
    elif cmd == "template" and len(a) == 3:
        p, src = find_template(a[1], year_arg(a[2]))
        if not p:
            sys.exit(f"no Revit {a[2]} project template found in the bottle")
        print(f"{p}\t{src}")
    elif cmd == "signin" and len(a) == 3:
        print(json.dumps(signin(a[1], year_arg(a[2]))))
    elif cmd == "verdict":
        pos, o = options(a[1:], ("--journal", "--replayed", "--since", "--outputs", "--watchdog", "--crash-log"),
                         ("--signin-seen", "--no-start"))
        if len(pos) != 1 or pos[0] not in SCENARIOS or "journal" not in o or "since" not in o:
            sys.exit(__doc__)
        if o.get("watchdog", "none") not in ("none", "start", "stall", "total"):
            sys.exit("--watchdog: none, start, stall or total")
        if not os.path.isfile(o["since"]) or not os.path.isfile(o["journal"]):
            sys.exit("--journal and --since must be files")
        print(json.dumps(verdict(pos[0], o["journal"], o.get("replayed", ""), o["since"], o.get("outputs"),
                                 o.get("watchdog", "none"), bool(o.get("signin-seen")), bool(o.get("no-start")),
                                 o.get("crash-log"))))
    elif cmd == "lint":
        paths = a[1:] or sorted(glob.glob(os.path.join(TEMPLATES, "*.txt")))
        if not paths:
            sys.exit("no journal templates found")
        problems = lint(paths)
        for p in problems:
            print(p)
        if problems:
            sys.exit(1)
        print(f"lint: ok ({len(paths)} journals)")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
