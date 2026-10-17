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

For the runner (scripts/smoke.sh):
  smoke.py clone-conf <cxbottle.conf> [--uuid UUID]
      rewrites [Bottle] of a copy: MenuMode and AssocMode ignore, a new BottleID; every other line stays
  smoke.py cut-links <clone_dir>
      each link under drive_c/users/crossover of a copy that leads out of it becomes an empty folder (an empty file
      for a link to a file); prints their paths in the copy; exit 1 if C: or the user folder is a link itself
  smoke.py conf-get <file.conf> <section> <key>
      the value of one key of a CrossOver .conf file (names without case); exit 1 if it has none
  smoke.py replayed <clone_dir> <year> --since MARKER
      "PATH<TAB>SIZE<TAB>IDLE" of the journal Revit writes for this run (IDLE 1 once it says appPriv idle); exit 1
      while there is none
  smoke.py result <state_dir> --out FILE
      writes result.json from what the runner kept in <state_dir>; prints the run's result (ok, failed,
      needs_person, prepare_failed, stopped)
  smoke.py summary <result.json> [--history LOGS_DIR]
      the table of scenarios and times, with the times of earlier passes of the same Revit year in LOGS_DIR

--journal is the journal we generated, --replayed the journal.NNNN.txt Revit wrote while playing it ('' if none),
--since the file touched just before Revit started, --outputs the Mac path of C:\\revit-smoke\\out. The runner says
what its watchdog did and whether it saw a sign-in process (--signin-seen) or no Revit at all (--no-start).

Revit's journals hold the Autodesk user name and file paths, so nothing here prints a line of one: only dialog ids,
the build, the release, line numbers and times; result.json holds no path of the Mac. Only journal, clone-conf,
cut-links and result write a file. Run with python3 -I -B.
"""
import datetime
import glob
import json
import ntpath
import os
import re
import stat as stat_mod
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bottleread import ini_get, journals_dir, newest_journal, read_conf, read_ini, read_lines  # noqa: E402
from signatures import journal_strong  # noqa: E402

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

STRONG = journal_strong()   # [(name, regex)]: the journal lines of tools/signatures.py that mean Revit crashed
WINE_CRASH = re.compile(r"wine: Unhandled (?:page fault|exception)")
# sign-in, licensing, EULA, trial: the words of a dialog id (TaskDialog_..., Dialog_..., split at _ and at case changes;
# two words in a row count too: Sign+In, Log+On, Ad+SSO), and a dialog's text
PERSON_WORDS = {"signin", "signout", "login", "logout", "logon", "eula", "trial", "adsso", "identity", "subscription"}
PERSON_PREFIX = ("licen", "entitle")
ID_WORD = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+")
# the same in a line of our own journal templates (lint): any part of a word, so an answer to such a dialog stands out
LINT_PERSON = re.compile(r"sign_?(?:in|out)|log_?(?:in|out|on)|licen[cs]|eula|trial|adsso|identity|entitle|"
                         r"subscription", re.I)
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
        for s, rx in STRONG:
            if s not in j["strong"] and rx.search(line):
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
            tasks[-1][1] = tasks[-1][1] or person_id(m.group(1))
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
                modals[-1][0], modals[-1][1] = m.group(1), person_id(m.group(1))
    j["dialogs"] = [tuple(d) for d in tasks + modals]
    j["modal_open"] = len(modals)
    if not j["release"] and (j["branch"] or "").startswith("RELEASE_"):
        j["release"] = j["branch"][8:]   # 2020 has no Release line, only Branch: RELEASE_2020
    return j


def person_id(did):
    """True for a dialog id that names sign-in, licensing, a EULA or a trial, by whole words:
    TaskDialog_License_Expired, Dialog_AdSSO; not TaskDialog_Invalid_Template (the "log" of Dialog, the "In" of
    Invalid) or Dialog_Design_Industrial."""
    words = [w.lower() for w in ID_WORD.findall(did or "")]
    words += [a + b for a, b in zip(words, words[1:])]
    return any(w in PERSON_WORDS or w.startswith(PERSON_PREFIX) for w in words)


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
    file name. Order: a crash before Revit was seen, a person must act, then pass, then fail with the first reason that
    applies."""
    stuck = watchdog not in (None, "", "none")
    ended = bool(j and j["finished"] and j["stopped_at"] is not None and exit_at and j["stopped_at"] >= exit_at)
    dialogs = [d for d in (j["dialogs"] if j else []) if not d[2]]   # leave out the dialog that reports a crash
    licensed = bool(j and (j["license_update"] or j["license_mode"]))

    def person(kind, reason, fix, did=None):
        return "person", kind, reason, fix, did

    def fail(kind, reason, did=None):
        return "fail", kind, reason, None, did

    if no_start and (crashed_wine or (j and j["strong"])):   # crash evidence comes before the fallback below
        why = j["strong"][0] if j and j["strong"] else "wine reported an unhandled exception"
        return fail("crash", f"Revit crashed while starting ({why})")
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


# --- runner: the copy's cxbottle.conf, the journal of a run, result.json and the summary ---

SECTION_LINE = re.compile(r"^\s*\[(.*)\]\s*(?:;[^\]]*)?$")
FIELD_LINE = re.compile(r'^(\s*)(;*\s*)"((?:[^"\\]|\\.)*)"(\s*=\s*)"((?:[^"\\]|\\.)*)"(.*)$')
JOURNAL_NAME = re.compile(r"journal\.\d{4}\.txt")
TEST_DIR = re.compile(r".+-test(?:-\d+)?")   # a test's log folder: <time>-test, or <time>-test-2 in the same second
RESULTS = {"pass": "passed", "fail": "failed", "person": "needs_person"}
WORDS = {"passed": "passed", "failed": "FAILED", "needs_person": "needs you", "skipped": "skipped",
         "stopped": "stopped"}
NOT_CHECKED = ["sign-in", "add-ins", "web panels", "how Revit looks"]
# the years whose start, core and reopen passed on a real Revit (a person adds a year after such a run); for any other
# year a failure can be the journal's own
REAL_REVIT = ()


def _conf_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def clone_conf(path, bottle_id):
    """Sets MenuMode and AssocMode to ignore (CrossOver makes no menu apps or file associations for the copy) and a new
    BottleID in [Bottle] of a copy's cxbottle.conf. Keys match without case, as CrossOver reads them; a key that is
    only there commented out is set on that line, as CrossOver itself does; a missing one goes after the section's
    last key. Every other line stays as it is, CRLF too. Written to a file next to it and renamed over it, so a reader
    sees the old file or the new one; the mode stays."""
    want = {"menumode": ("MenuMode", "ignore"), "assocmode": ("AssocMode", "ignore"),
            "bottleid": ("BottleID", bottle_id)}
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", errors="surrogateescape")
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(nl)
    start = next((i for i, l in enumerate(lines) if (m := SECTION_LINE.match(l)) and m.group(1).lower() == "bottle"),
                 None)
    if start is None:
        raise SystemExit(f"no [Bottle] section in {os.path.basename(path)}")
    end = next((i for i in range(start + 1, len(lines)) if SECTION_LINE.match(lines[i])), len(lines))

    def field(i):
        m = FIELD_LINE.match(lines[i])
        return (m, _unescape(m.group(3)).lower()) if m else (None, None)

    def put(i, m, key):
        name, value = want[key]
        lines[i] = f'{m.group(1)}"{_conf_escape(name)}"{m.group(4)}"{_conf_escape(value)}"'

    done, last = set(), start
    for i in range(start + 1, end):
        m, key = field(i)
        if m:
            last = i
            if key in want and not m.group(2).strip():
                put(i, m, key)
                done.add(key)
    for i in range(start + 1, end):
        m, key = field(i)
        if m and key in want and key not in done:
            put(i, m, key)
            done.add(key)
    for key in [k for k in want if k not in done]:
        name, value = want[key]
        last += 1
        lines.insert(last, f'"{name}" = "{_conf_escape(value)}"')
    mode = stat_mod.S_IMODE(os.stat(path).st_mode)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".cxbottle.conf.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(nl.join(lines).encode("utf-8", errors="surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    got = {k.lower(): v for k, v in conf_section(path, "Bottle").items()}
    if any(got.get(k) != v for k, (_, v) in want.items()):
        raise SystemExit(f"{os.path.basename(path)}: the new values did not stick")


def _unescape(s):
    return re.sub(r"\\(.)", r"\1", s)


def conf_section(path, section):
    """One section of a CrossOver .conf file ({} if there is none), the section name matched without case."""
    for name, keys in read_conf(path).items():
        if name.lower() == section.lower():
            return keys
    return {}


def conf_get(path, section, key):
    return next((v for k, v in conf_section(path, section).items() if k.lower() == key.lower()), None)


USER_DIR = ("drive_c", "users", "crossover")


def cut_links(clone):
    """Replaces each link under drive_c/users/crossover of a copy that leads out of the copy (CrossOver links Documents,
    Desktop, Downloads and the like to the Mac's own folders) with an empty folder, or an empty file for a link to a
    file, so that Revit in the copy writes nothing outside it. Only the links themselves change: nothing is followed,
    read or deleted through one. Returns their paths in the copy, sorted. SystemExit when drive_c, users or crossover
    is a link itself (C: or the user folder of the copy would be another folder)."""
    root = os.path.realpath(clone)
    top = root
    for part in USER_DIR:
        top = os.path.join(top, part)
        if os.path.islink(top):
            raise SystemExit(f"{'/'.join(USER_DIR)} of the copy goes through a link ({part})")
    if not os.path.isdir(top):
        return []
    out = []
    for d, dirs, files in os.walk(top):   # a link to a folder is listed in dirs and never entered
        for n in dirs + files:
            p = os.path.join(d, n)
            if not os.path.islink(p):
                continue
            target = os.path.realpath(p)   # through every link on the way; what does not exist stays as written
            if target == root or target.startswith(root + os.sep):
                continue
            to_file = os.path.isfile(p)
            try:
                os.unlink(p)
                if to_file:
                    open(p, "xb").close()
                else:
                    os.mkdir(p)
            except OSError as e:
                raise SystemExit(f"could not replace a link in the copy: {e.strerror}")
            out.append(os.path.relpath(p, root).replace(os.sep, "/"))
    return sorted(out)


def replayed(clone, year, since_ns):
    """(path, size, idle) of the journal Revit writes for this run: the newest journal.NNNN.txt that is not older than
    the start marker, in C:\\revit-smoke first (2026 and newer write it there while they play a journal), else in
    AppData's Journals. None while there is none."""
    for d in (os.path.join(clone, "drive_c", "revit-smoke"), journals_dir(clone, year)):
        best = None
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not JOURNAL_NAME.fullmatch(n):
                continue
            p = os.path.join(d, n)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if stat_mod.S_ISREG(st.st_mode) and st.st_mtime_ns >= since_ns and (best is None or
                                                                                 (st.st_mtime_ns, n) > best[0]):
                best = ((st.st_mtime_ns, n), p, st.st_size)
        if best:
            return best[1], best[2], any("appPriv idle" in line for line in read_lines(best[1]))
    return None


def read_kv(path):
    """key=value lines (the last one of a key counts); {} for a missing file."""
    out = {}
    for line in read_lines(path) if os.path.isfile(path) else ():
        k, sep, v = line.partition("=")
        if sep and re.fullmatch(r"[a-z_]+", k):
            out[k] = v
    return out


def _load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _int(s):
    return int(s) if re.fullmatch(r"\d+", s or "") else None


def _flag(s):
    return {"1": True, "0": False}.get(s or "")


def template_entry(path, source):
    """The template for result.json: its path only when it is one of Autodesk's (C:\\ProgramData\\Autodesk\\...); a
    template of the user's own may name a firm or a client."""
    if not path:
        return None
    ours = bool(re.match(r"(?i)C:\\ProgramData\\Autodesk\\", path)) and journal_safe(path) and path.isascii()
    return {"path": path if ours else None, "source": source or None, "own": not ours}


def build_result(state):
    """result.json as a dict, from the runner's state folder: meta (key=value lines) and, per scenario that ran,
    <name>.verdict.json (smoke.py verdict) and <name>.run (seconds, watchdog, worker_killed, signin_seen, no_start,
    stopped), links (what cut-links printed). A copy that could not be deleted (copy_removed=0, not kept) makes the run
    failed and keeps each scenario's result."""
    meta = read_kv(os.path.join(state, "meta"))
    links = []   # the links of the copy that cut-links replaced, each once
    for line in read_lines(os.path.join(state, "links")):
        if line and line not in links:
            links.append(line)
    names = [n for n in meta.get("scenarios", "").split() if n in SCENARIOS]
    prep = meta.get("prepare", "")
    stopped = meta.get("stopped") == "1"
    scen, overall, before = [], None, None
    for name in names:
        run = read_kv(os.path.join(state, name + ".run"))
        v = _load(os.path.join(state, name + ".verdict.json"))
        e = {"name": name}
        if isinstance(v, dict) and v.get("verdict") in RESULTS:
            e["result"] = RESULTS[v["verdict"]]
            e.update({k: v.get(k) for k in ("kind", "reason", "fix", "dialog_id", "build", "release", "stopped_at",
                                            "exit_line", "t_start_idle", "t_total", "longest_gap", "outputs")})
        elif run.get("stopped") == "1":
            e["result"], e["reason"] = "stopped", "stopped by a signal (Ctrl-C)"
        elif run:
            e["result"], e["reason"] = "failed", run.get("error") or "the run gave no verdict"
        else:
            e["result"] = "skipped"
            e["reason"] = before or ("the copy was not ready" if prep != "ok" else "the test stopped before it")
        if run:
            e.update({"seconds": _int(run.get("seconds")), "watchdog": run.get("watchdog") or "none",
                      "revit_worker_killed": run.get("worker_killed") == "1",
                      "signin_seen": run.get("signin_seen") == "1", "no_start": run.get("no_start") == "1"})
        if e["result"] not in ("passed", "skipped") and before is None:
            before = f"{name} did not pass"
            overall = overall or {"needs_person": "needs_person", "stopped": "stopped"}.get(e["result"], "failed")
        scen.append(e)
    if stopped:
        overall = "stopped"
    elif prep and prep != "ok":
        overall = "prepare_failed"
    elif overall is None:
        ran = [e for e in scen if e["result"] != "skipped"]
        overall = "ok" if ran and not meta.get("error") else "failed"
    left = meta.get("copy_removed") == "0" and meta.get("kept") != "1"
    if left and not stopped:   # a signed-in copy left behind fails the run, whatever its scenarios gave
        overall = "failed"
    year = _int(meta.get("year"))
    return {
        "format": 1, "tool": "./revit test", "run_id": meta.get("run_id") or None, "time": meta.get("time") or None,
        "year": year, "bottle": meta.get("bottle") or None, "copy": meta.get("copy") or None, "result": overall,
        "reason": meta.get("error") or (meta.get("prepare_reason") or None if prep and prep != "ok" else None),
        "crossover": meta.get("crossover") or None, "engine": meta.get("engine") or None,
        "prepare": {"ok": {"ok": True, "failed": False}.get(prep), "upgraded": _flag(meta.get("upgraded")),
                    "seconds": _int(meta.get("prepare_seconds")), "reason": meta.get("prepare_reason") or None},
        "template": template_entry(meta.get("template"), meta.get("template_source")),
        "scenarios": scen, "copy_removed": _flag(meta.get("copy_removed")), "copy_kept": meta.get("kept") == "1",
        "copy_problem": (meta.get("copy_problem") or None) if left else None, "links_replaced": links,
        "not_checked": NOT_CHECKED, "journals_on_real_revit": year in REAL_REVIT,
    }


def write_result(state, out):
    res = build_result(state)
    tmp = out + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1)
        f.write("\n")
    os.replace(tmp, out)
    return res


def _secs(x):
    return f"{x:g} s" if isinstance(x, (int, float)) else "?"


def earlier(res, history, here):
    """{scenario: [(t_start_idle, t_total), ...]} of the newest earlier passes (at most 3 each) of the same Revit year,
    from the result.json files of other test runs in the log folder."""
    out = {}
    if not history or not res.get("year"):
        return out
    seen = []
    for p in glob.glob(os.path.join(history, "*", "*-test*", "result.json")):
        if not TEST_DIR.fullmatch(os.path.basename(os.path.dirname(p))):
            continue
        if here and os.path.realpath(p) == os.path.realpath(here):
            continue
        r = _load(p)
        if (isinstance(r, dict) and r.get("year") == res["year"] and isinstance(r.get("time"), str)
                and (not res.get("time") or r["time"] < res["time"]) and isinstance(r.get("scenarios"), list)):
            seen.append(r)
    for r in sorted(seen, key=lambda r: r["time"], reverse=True):
        for s in r["scenarios"]:
            if isinstance(s, dict) and s.get("result") == "passed" and isinstance(s.get("t_total"), (int, float)):
                lst = out.setdefault(s.get("name"), [])
                if len(lst) < 3:
                    lst.append((s.get("t_start_idle"), s["t_total"]))
    return out


def summary(res, history=None, here=None):
    """The lines ./revit test prints at the end: one per scenario, earlier times, what it does not check."""
    year, bottle = res.get("year"), res.get("bottle") or ""
    sfx = "" if bottle == f"rvt{year}-a" else f" {bottle}"
    build = next(((s.get("release"), s.get("build")) for s in res.get("scenarios", []) if s.get("build")), None)
    head = f"Revit {year} in a temporary copy of {bottle}"
    if build:
        head += f" (release {build[0] or '?'}, build {build[1]})"
    lines = [head + ":"]
    if res.get("result") == "prepare_failed":
        lines.append(f"  CrossOver could not prepare the copy: {res.get('reason') or 'no reason given'}.")
        lines.append("  This is not a Revit failure, and your bottle is not changed.")
    elif res.get("reason"):
        lines.append(f"  The test did not run: {res['reason']}.")
    if res.get("copy_removed") is False and not res.get("copy_kept"):
        why = f": {res['copy_problem']}" if res.get("copy_problem") else ""
        lines.append(f"  The temporary copy {res.get('copy') or '?'} was not deleted{why}. The test counts as failed.")
        lines.append(f"  Run ./revit test {year}{sfx} again: it deletes the copy first (if programs still run in it, "
                     "restart the Mac first). Or delete it in CrossOver.")
    past = earlier(res, history, here)
    for s in res.get("scenarios", []):
        word = WORDS.get(s.get("result"), s.get("result") or "?")
        if s.get("result") == "passed":
            text = (f"Revit ready in {_secs(s.get('t_start_idle'))}, done in {_secs(s.get('t_total'))}, "
                    f"longest pause {_secs(s.get('longest_gap'))}")
        else:
            text = s.get("reason") or ""
        lines.append(f"  {s.get('name', '?'):<7} {word:<10} {text}".rstrip())
        if s.get("fix"):
            lines.append(f"  {'':<7} {'':<10} {s['fix']}")
        if s.get("result") == "passed" and past.get(s.get("name")):
            ready = "/".join(_secs(a)[:-2] for a, _ in past[s["name"]])
            done = "/".join(_secs(b)[:-2] for _, b in past[s["name"]])
            lines.append(f"  {'':<7} {'':<10} earlier passes: ready in {ready} s, done in {done} s")
    if year not in REAL_REVIT:
        lines.append(f"These journals were not run on a real Revit {year} yet: a failure can be theirs, not Revit's.")
    lines.append("Not checked: " + ", ".join(NOT_CHECKED) + ".")
    lines.append(f"To share this result: ./revit report {year}{sfx}")
    return lines


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
            if LINT_PERSON.search(s):
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
    elif cmd == "clone-conf":
        pos, o = options(a[1:], ("--uuid",))
        if len(pos) != 1 or not os.path.isfile(pos[0]):
            sys.exit(__doc__)
        bid = o.get("uuid") or str(uuid.uuid4()).upper()
        if not re.fullmatch(r"[0-9A-Za-z-]{2,}", bid):   # what cxbottle --set-uuid accepts
            sys.exit("--uuid: letters, digits and -")
        clone_conf(pos[0], bid)
    elif cmd == "cut-links" and len(a) == 2:
        for p in cut_links(a[1]):
            print(p)
    elif cmd == "conf-get" and len(a) == 4:
        v = conf_get(a[1], a[2], a[3])
        if v is None:
            sys.exit(1)
        print(v)
    elif cmd == "replayed":
        pos, o = options(a[1:], ("--since",))
        if len(pos) != 2 or "since" not in o or not os.path.isfile(o["since"]):
            sys.exit(__doc__)
        r = replayed(pos[0], year_arg(pos[1]), os.stat(o["since"]).st_mtime_ns)
        if not r:
            sys.exit(1)
        print(f"{r[0]}\t{r[1]}\t{int(r[2])}")
    elif cmd == "result":
        pos, o = options(a[1:], ("--out",))
        if len(pos) != 1 or "out" not in o or not os.path.isdir(pos[0]):
            sys.exit(__doc__)
        print(write_result(pos[0], o["out"])["result"])
    elif cmd == "summary":
        pos, o = options(a[1:], ("--history",))
        if len(pos) != 1:
            sys.exit(__doc__)
        res = _load(pos[0])
        if not isinstance(res, dict):
            sys.exit(f"cannot read {os.path.basename(pos[0])}")
        print("\n".join(summary(res, o.get("history"), pos[0])))
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
