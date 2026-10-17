#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The catalog of failure signatures: lines in the logs of Revit, Wine and an install that mean something broke.

  signatures.py list [--json]
      the catalog
  signatures.py scan <file>... [--where cxlog|journal|steplog|msilog] [--year Y] [--lines N] [--from-start] [--json]
      hits per signature and file: counts, line numbers, the process of a crash; never a line of a log

Each signature: id; where (cxlog: a debug session's wine.cxlog and stdout.log, journal: a Revit journal, steplog: an
install's step logs, msilog: its MSI logs); pattern (a short regex); level (warn: something broke; info: a count for
the JSON only); years ("all" or a list); meaning and fix in the words of the user pages; doc (an anchor in
docs/troubleshooting.md, or ""); source (where the knowledge comes from). One list for every reader: ./revit doctor
(tools/doctor.py, its logs group), ./revit test (tools/smoke.py takes the journal signatures as its crash classifier)
and ./revit report (tools/report.py takes the warn signatures into the lines of a log it keeps).

scan_file() reads a file once, through bottleread.read_lines (binary-safe, up to the length the file had when it was
looked at, long lines cut), with one combined pattern for all its signatures. Of a big file it reads its last
LINES_MAX lines only, at most WINDOW bytes: a session that crashed ends with the crash, so the cap leaves out the start
(the line ends are counted backwards from its end, fast, to find where its last lines begin). The part before is never
read, so the line numbers of such a scan count from its first line read ("relative"). It keeps at most HITS_MAX line
numbers of a signature (the count goes on). A crash line names its thread ("(thread 0b18)"); the process is the one
whose lines of the same file carry that thread id and whose program Wine loaded, else "process unknown": no guess from
a nearby line. Run with python3 -I -B.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bottleread  # noqa: E402

LINES_MAX = 3000000       # lines read of one file at most
WINDOW = 384 << 20        # bytes read of one file at most: of a bigger file, its end
HITS_MAX = 20             # line numbers kept per signature and file
CHUNK = 4 << 20           # the block the line ends of a big file are counted in
UTF16_MAX = 64 << 20      # a UTF-16 log (an MSI log can be one) is read whole up to this
WHERE = ("cxlog", "journal", "steplog", "msilog")
TS = "docs/troubleshooting.md#"
REBUILD = "{rebuild}"     # doctor puts its rebuild advice here: ./revit rebuild <year>: it shows what it resets...


class Sig:
    """One signature. lits: literals a matching line holds one of (the fast search of tools/report.py through a big
    log); name: how ./revit test names it in a verdict."""

    def __init__(self, id_, where, pattern, level, years, meaning, fix, doc, source, lits, name=None):
        self.id, self.where, self.pattern, self.level, self.years = id_, where, pattern, level, years
        self.meaning, self.fix, self.doc, self.source, self.lits = meaning, fix, doc, source, tuple(lits)
        self.name = name or id_
        self.rx = re.compile(pattern)

    def for_year(self, year):
        return self.years == "all" or year is None or int(year) in self.years

    def json(self):
        return {"id": self.id, "where": self.where, "pattern": self.pattern, "level": self.level,
                "years": self.years if self.years == "all" else list(self.years), "meaning": self.meaning,
                "fix": self.fix.replace(REBUILD, "./revit rebuild <year>: it shows what it resets and asks first"),
                "doc": TS + self.doc if self.doc else "", "source": self.source}


REPORT = "report-a-problem"
CATALOG = (
    # ---- a debug session: wine.cxlog and stdout.log (an earlier signature wins a line) ----
    Sig("wine-crash", "cxlog", r"wine: Unhandled (?:page fault|exception)", "warn", "all",
        "a Windows program in the bottle crashed", "", REPORT,
        "Wine prints this line when a program has no handler for an exception; 0 in healthy sessions",
        ("wine: Unhandled ",)),
    Sig("netfx-80131506", "cxlog", r"exit code 80131506", "warn", (2020,),
        "Revit 2020 stopped with an internal error of .NET Framework (80131506)",
        "do not install .NET Framework 4.7.2 or 4.8 in the bottle; " + REBUILD,
        "revit-2020-crashes-on-start-after-installing-net-framework-472-or-48",
        ".NET Framework's error code when Revit 2020 runs on .NET Framework 4.7.2 or 4.8 instead of the 4.7 of its "
        "installer", ("exit code 80131506",)),
    Sig("dotnet-fatal", "cxlog", r"err:eventlog:ReportEventW", "warn", "all",
        ".NET reported a fatal error or an unhandled exception in a program in the bottle", "", REPORT,
        ".NET writes its fatal errors to the Windows event log, which Wine prints; 0 in healthy sessions",
        ("err:eventlog:ReportEventW",)),
    Sig("wine-missing-function", "cxlog", r"unimplemented function [\w.-]+\.dll\.\w+", "warn", "all",
        "a program called a Windows function that Wine does not have", "", REPORT,
        "Wine names a function it lacks when a program calls it; the known ones are fixed at install",
        ("unimplemented function ",)),
    Sig("metal-assertion", "cxlog", r"MTLTextureDescriptor has invalid pixelFormat|failed assertion .Texture "
        r"Descriptor Validation", "warn", "all",
        "Apple's Metal stopped a drawing call of Revit with an assertion", "", REPORT,
        "Apple's Metal checks each texture Revit asks for; seen once, in a Revit 2024 session that then lost its "
        "main thread", ("MTLTextureDescriptor has invalid pixelFormat", "Texture Descriptor Validation")),
    Sig("assertion", "cxlog", r"Assertion failed", "warn", "all",
        "a program in the bottle stopped on a failed assertion", "", REPORT,
        "the C library's message for a failed assertion; in the built-in browser it ends the browser process",
        ("Assertion failed",)),
    Sig("ecdsa-verify", "cxlog", r'dispatch_exception "\[ncrypt-shim\] VerifySignature\(\d+ bytes\) -> 0x[0-9a-f]+',
        "info", "all",
        "Revit's ECDSA signature checks, counted: in Revit 2024 and newer all of them fail, with no known effect",
        "", "", "the trace of the fix for Wine's ECDSA keys, counted once a check (its dispatch_exception line)",
        ("VerifySignature(",)),
    # ---- a Revit journal: ./revit test's crash classifier (tools/smoke.py), matched without case ----
    Sig("journal-unrecoverable", "journal", r"(?i:unrecoverable error)", "warn", "all",
        "Revit closed with an unrecoverable error", "", REPORT,
        "Revit writes it to its journal before it closes on a fatal error",
        ("unrecoverable error", "Unrecoverable error", "Unrecoverable Error"), name="unrecoverable error"),
    Sig("journal-exception", "journal", r"(?i:Exception occurred)", "warn", "all",
        "Revit reported an exception", "", REPORT, "Revit writes it to its journal when it catches an exception",
        ("Exception occurred",), name="Exception occurred"),
    Sig("journal-capture-crash", "journal", r"(?i:captureTryCrash)", "warn", "all",
        "Revit caught a crash in its own code", "", REPORT,
        "Revit's journal line for a structured exception it caught; 0 in 114 healthy journals",
        ("captureTryCrash",), name="captureTryCrash"),
    Sig("journal-assertion", "journal", r"(?i:Assertion failed)", "warn", "all",
        "Revit stopped on a failed assertion", "", REPORT,
        "Revit's journal line for a failed internal check, for example when Wine could not import its key",
        ("Assertion failed",), name="Assertion failed"),
    # ---- an install's step logs ----
    Sig("licensing-no-answer", "steplog", r"licensing service does not answer", "warn", "all",
        "the install stopped: the Autodesk licensing service did not answer", REBUILD,
        "install-stops-the-autodesk-licensing-service-does-not-answer",
        "the check before RVT.msi (scripts/steps/revit.sh): RVT.msi fails when the service is silent",
        ("licensing service does not answer",)),
    Sig("licensing-install-failed", "steplog", r"the licensing installer returned \d+|no AdskLicensing version "
        r"folder|no helper in ", "warn", "all", "the install of Autodesk licensing failed", REBUILD, "start-over",
        "scripts/steps/licensing.sh, when the licensing installer fails in a way it does not accept",
        ("the licensing installer returned ", "no AdskLicensing version folder", "no helper in ")),
    # ---- an install's MSI logs ----
    Sig("msi-failed", "msilog", r"Return value 3\b|: INSTALL\. Return value 0\b", "warn", "all",
        "an MSI package failed to install", REBUILD, "start-over",
        "Windows Installer logs Return value 3 for a failed action; Wine's MSI logs 0 for a failed INSTALL",
        ("Return value 3", "INSTALL. Return value 0")),
)
BY_ID = {s.id: s for s in CATALOG}

# a cxlog line of Wine: <seconds>:<pid>:<tid>:<class>:<channel>:...; the program a process loads; a crash's thread
PREFIX = re.compile(r"^\s*\d+\.\d+:([0-9a-f]{4,8}):([0-9a-f]{4,8}):")
LOADED = re.compile(r':trace:loaddll:\w+ Loaded L"(?:[^"]*\\)?([^"\\]{1,80}\.(?i:exe))"')
THREAD = re.compile(r"\(thread ([0-9a-f]{1,8})\)|in thread ([0-9a-f]{1,8})\b")
PROCESS_OK = re.compile(r"^[A-Za-z0-9 _.()+-]{1,64}\.(?i:exe)$")
DETAIL = {"wine-missing-function": re.compile(r"unimplemented function ([A-Za-z0-9_.-]{1,64}\.dll\.\w{1,64})")}
RESULT = re.compile(r"-> 0x([0-9a-f]+)")


def of(where, year=None, level=None):
    """The signatures of one kind of log, in catalog order (an earlier one wins a line)."""
    return [s for s in CATALOG if s.where == where and s.for_year(year) and level in (None, s.level)]


def journal_strong():
    """[(name, regex)] of the warn signatures of a journal: the crash classifier of ./revit test."""
    return [(s.name, s.rx) for s in of("journal", level="warn")]


def journal_rx():
    """One regex for the signature lines of a journal (tools/report.py keeps them in its journal extract)."""
    return re.compile("|".join(s.pattern for s in of("journal")))


def error_lines():
    """((literal, pattern), ...) of the warn signatures of every kind: the lines of a log tools/report.py may keep."""
    out = []
    for s in CATALOG:
        if s.level == "warn":
            out += [(lit, s.pattern) for lit in s.lits]
    return tuple(out)


def where_of(name):
    """The kind of log a file name is, or None."""
    n = name.lower()
    if n.endswith(".cxlog") or n == "stdout.log":
        return "cxlog"
    if re.fullmatch(r"journal\.\d+\.txt", n):
        return "journal"
    if n.endswith(".msi.log"):
        return "msilog"
    if n.endswith(".log"):
        return "steplog"
    return None


def _utf16(path):
    try:
        with open(path, "rb") as f:
            head = f.read(512)
    except OSError:
        return False
    if head.startswith((b"\xff\xfe", b"\xfe\xff")):
        return True
    return len(head) >= 4 and head[1::2].count(0) > len(head) // 4 and head[0::2].count(0) < len(head) // 8


def _utf16_lines(path):
    with open(path, "rb") as f:
        raw = f.read(UTF16_MAX)
    text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-16-le", "replace")
    for line in text.splitlines():
        yield line[:4000]


def _start(path, size, lines_max, window):
    """Where to begin in a file: 0 when all of it fits, else the start of its last lines_max lines, at most window
    bytes before the end. The line ends are counted backwards from the end in blocks (bytes.count, fast), so the cap
    leaves out the start of a big file, never its end."""
    if size <= lines_max and size <= window:
        return 0
    left, pos = lines_max, size
    try:
        with open(path, "rb") as f:
            f.seek(size - 1)
            left += f.read(1) == b"\n"   # the line end of the last line is no line before it
            while True:
                lo = max(0, pos - CHUNK, size - window)
                if lo >= pos:
                    return pos   # window bytes counted: the line pos falls in is skipped
                f.seek(lo)
                buf = f.read(pos - lo)
                c = buf.count(b"\n")
                if c < left:
                    left, pos = left - c, lo
                    if lo == 0:
                        return 0
                    continue
                j = len(buf)
                for _ in range(left):   # the left-th line end from the end of this block
                    j = buf.rfind(b"\n", 0, j)
                return lo + j + 1
    except OSError:
        return 0


def scan_file(path, where=None, year=None, lines_max=LINES_MAX, window=WINDOW, hits_max=HITS_MAX, from_start=False):
    """One pass over a log -> {"where", "size", "start", "relative", "lines", "cut", "hits", "metrics"}.
    hits: {id: {"count", "lines": [line numbers], "details": [process or function names]}}; metrics: counts of the
    info signatures (ecdsa-verify: {"failed", "passed"}). start: the byte reading began at (0 unless the file is
    big); relative: True when it began after 0, so the line numbers count from the first line read (line 1 is the
    first whole line after byte start), not from the start of the file; cut: "lines" when lines_max stopped it before
    its end. from_start: read from the start (up to lines_max lines) even when the file is big."""
    where = where or where_of(os.path.basename(path))
    out = {"where": where, "size": 0, "start": 0, "relative": False, "lines": 0, "cut": None, "hits": {},
           "metrics": {}}
    sigs = of(where, year) if where in WHERE else []
    if not sigs:
        return out
    try:
        size = os.path.getsize(path)
    except OSError:
        return out
    out["size"] = size
    utf16 = _utf16(path)
    start = 0 if utf16 or from_start else _start(path, size, lines_max, window)
    if start:   # read_lines skips the line that holds byte start - 1; what comes before is not counted
        out["start"], out["relative"] = start, True
    one = re.compile("|".join("(?:%s)" % s.pattern for s in sigs))
    lines = _utf16_lines(path) if utf16 else bottleread.read_lines(path, max_bytes=size, start=start)
    threads, programs = {}, {}   # tid -> pid, pid -> the program it loaded (the latest one: pids come back)
    hits, metrics, cx = out["hits"], out["metrics"], where == "cxlog"
    n = 0
    for line in lines:
        n += 1
        if n > lines_max:
            out["cut"], n = "lines", n - 1
            break
        if cx and (":warn:seh:" in line or ":trace:loaddll:" in line):   # who runs which thread
            m = PREFIX.match(line)
            if m:
                threads[m.group(2)] = m.group(1)
                ld = LOADED.search(line) if ":trace:loaddll:" in line else None
                if ld:
                    programs[m.group(1)] = ld.group(1)
        if not one.search(line):
            continue
        sig = next((s for s in sigs if s.rx.search(line)), None)
        if sig is None:
            continue
        if sig.level == "info":
            r = RESULT.search(line)
            c = metrics.setdefault(sig.id, {"failed": 0, "passed": 0})
            c["passed" if r and int(r.group(1), 16) == 0 else "failed"] += 1
            continue
        h = hits.setdefault(sig.id, {"count": 0, "lines": [], "details": []})
        h["count"] += 1
        if len(h["lines"]) < hits_max:
            h["lines"].append(n)
        detail = None
        if sig.id == "wine-crash":
            t = THREAD.search(line)
            tid = (t.group(1) or t.group(2)).zfill(4) if t else None
            prog = programs.get(threads.get(tid)) if tid else None
            detail = prog if prog and PROCESS_OK.match(prog) else "process unknown"
        elif sig.id in DETAIL:
            d = DETAIL[sig.id].search(line)
            detail = d.group(1) if d else None
        if detail and detail not in h["details"] and len(h["details"]) < 5:
            h["details"].append(detail)
    out["lines"] = n
    return out


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    if not a or a[0] not in ("list", "scan"):
        sys.exit(__doc__)
    as_json = "--json" in a
    a = [x for x in a if x != "--json"]
    if a[0] == "list":
        if as_json:
            print(json.dumps([s.json() for s in CATALOG], indent=1))
        else:
            for s in CATALOG:
                print("%-24s %-8s %-5s %s" % (s.id, s.where, s.level, s.meaning))
        return 0
    files, opt, i = [], {"where": None, "year": None, "lines": str(LINES_MAX), "from-start": False}, 1
    while i < len(a):
        if a[i] in ("--where", "--year", "--lines") and i + 1 < len(a):
            opt[a[i][2:]] = a[i + 1]
            i += 2
        elif a[i] == "--from-start":
            opt["from-start"] = True
            i += 1
        elif a[i].startswith("--"):
            sys.exit("%s: unknown option or missing value" % a[i])
        else:
            files.append(a[i])
            i += 1
    if not files or (opt["where"] and opt["where"] not in WHERE) or not opt["lines"].isdigit() or \
            (opt["year"] and not re.fullmatch(r"20\d\d", opt["year"])):
        sys.exit(__doc__)
    res = {}
    for f in files:
        res[f] = scan_file(f, opt["where"], opt["year"], int(opt["lines"]), from_start=opt["from-start"])
    if as_json:
        print(json.dumps(res, indent=1))
        return 0
    for f, r in res.items():
        print("%s: %s, %d lines%s%s" % (os.path.basename(f), r["where"], r["lines"],
                                         " from byte %d (line numbers count from there)" % r["start"]
                                         if r["relative"] else "", ", cut at the line cap" if r["cut"] else ""))
        for sid, h in r["hits"].items():
            print("  %-24s %d (lines %s)%s" % (sid, h["count"], " ".join(map(str, h["lines"][:5])),
                                              ("; " + ", ".join(h["details"])) if h["details"] else ""))
        for sid, m in r["metrics"].items():
            print("  %-24s %s" % (sid, " ".join("%s %d" % kv for kv in sorted(m.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
