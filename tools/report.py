#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A report for a GitHub issue with personal data removed: report.txt to paste, report.zip to attach.

  report.py build --root R --data D --bottles B [--year Y --bottle N] [--run DIR] [--doctor-json F]
                  [--exclude NAME]... --out-dir DIR [--json]
  report.py gate <file>... [--root R --data D --bottles B --year Y --bottle N]

build takes files by type and only the parts that help (never a whole log, nothing from sign-in, licensing or a
browser), puts placeholders such as <USER> where personal data was, then checks every part again with a gate that does
not trust the replacing. A part that fails the gate is left out and report.txt says so; when report.txt itself fails,
there is no report (exit 1). The parts are made in a private temporary folder; only what passed is moved to DIR.
--json prints {report_txt, report_zip, left_out[], summary, refused, hits}.

gate checks finished files (a zip member by member): each hit as rule, file, line, value class and length, never the
value; exit 1 on any hit.

What it learns about this Mac and the bottle (user name, computer name, serial number, the Autodesk user name and ID)
stays in memory: it is never written or printed. Nothing is sent anywhere. A library too: learn_identity, redact,
gate, journal_extract, msi_extract, cxlog_extract, build. Run with python3 -I -B.
"""
import argparse
import bisect
import collections
import itertools
import json
import os
import platform
import plistlib
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bottleread  # noqa: E402

REPORT_MAX = 20 * 1024          # report.txt: well inside a GitHub issue body (~65,000 characters)
ZIP_MAX = 5 * 1024 * 1024
MEMBER_MAX = 256 * 1024
LINE_MAX = 2000
TAIL = 200                      # lines of a cxlog, a failed step's log, a failed action's log
MSI_BEFORE, MSI_WINDOWS = 40, 10
JOURNAL_MAX = 1000              # kept journal lines
NUL_MAX = 0.01

# ---- placeholders: class -> (token, what the summary calls it). {} in a token is a number (same value, same number)
LABELS = {
    "user": ("<USER>", "your user name"), "name": ("<NAME>", "your name"), "home": ("~", "home folder path"),
    "data": ("<DATA>", "data folder path"), "repo": ("<REPO>", "project folder path"),
    "host": ("<HOST>", "Mac name"), "adsk_user": ("<ADSK-USER>", "Autodesk user name"),
    "adsk_id": ("<ADSK-ID>", "Autodesk ID"), "serial": ("<MAC-SERIAL>", "Mac serial number"),
    "hw_uuid": ("<HW-UUID>", "hardware UUID"), "mac": ("<MAC-ADDR>", "network address"),
    "email": ("<EMAIL>", "email address"), "bottle": ("<BOTTLE>", "bottle name"),
    "private": ("<PRIVATE>", "word from your list"), "volume": ("<VOLUME-{}>", "volume name"),
    "model": ("<MODEL-{}>", "model name"), "dir": ("<DIR-{}>", "folder name"),
    "secret": ("<SECRET>", "sign-in token"), "query": ("<VALUE>", "web address value"),
    "adsk_serial": ("<SERIAL>", "Autodesk serial number"), "tmpdir": ("<TMPDIR>", "temporary folder path"),
}
ORDER = ("user", "name", "home", "data", "repo", "host", "adsk_user", "adsk_id", "serial", "hw_uuid", "mac", "email",
         "bottle", "private", "volume", "model", "dir", "secret", "query", "adsk_serial", "tmpdir")
NUMBERED = ("volume", "model", "dir")
PHASE = {"adsk_user": 1, "adsk_id": 1, "host": 2}   # Autodesk identity, then the host, then the other words (3)
TOKEN = re.compile(r"<(?:DATA|REPO|USER|NAME|HOST|ADSK-USER|ADSK-ID|MAC-SERIAL|HW-UUID|MAC-ADDR|EMAIL|BOTTLE|PRIVATE|"
                   r"TMPDIR|SECRET|JWT|CALLBACK|VALUE|SERIAL|(?:VOLUME|MODEL|DIR)-\d+)>", re.I)

# While redacting, a replaced span is a run of private-use characters: later rules cannot match inside it
S_OPEN, S_CLOSE, S_HOME = "\ue000", "\ue001", "\ue002"
S_ANY = "\ue000-\ue1ff"
S_RX = re.compile(S_OPEN + "([\ue100-\ue109]+)" + S_CLOSE)
S_ONLY = re.compile("[" + S_ANY + r"\s]*")

SEP = r"(?:[\\/]|%2[Ff]|%5[Cc])+"                     # / \ \\ \/ (JSON) %2F %5C
END = r"(?!\w|[-.]\w)"                                # a path value ends here, not inside a longer name
DRIVE = r"(?:(?<![A-Za-z])[A-Za-z]:)?"                # Z: and the like, not the e: of file:
_NOSEP = r"(?!%2[Ff]|%5[Cc])"

TMPDIR_RX = re.compile(DRIVE + r"(?:" + SEP + r"private)?" + SEP + r"var" + SEP + r"folders" + SEP +
                       r"[^\\/\s%]{1,4}" + SEP + r"[^\\/\s%]{4,40}" + SEP + r"[TC](?!\w)", re.I)
JWT_RX = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")
BEARER_RX = re.compile(r"(?i)(\bbearer\s+)([A-Za-z0-9._~+/=-]{8,})")
CALLBACK_RX = re.compile(r"(?i)(\badskidmgr:)([^\s\"'<>" + S_ANY + r"]+)")
KEYSECRET_RX = re.compile(r"(?i)\b(access_token|refresh_token|id_token|client_secret|code_verifier|password|passwd)"
                          r"([\"']?\s{0,2}[=:]\s{0,2}[\"']?)([^\s\"'&,;<>" + S_ANY + r"]{6,})")
URL_RX = re.compile(r"(?i)(\bhttps?:(?://|" + SEP + r")[^\s?#\"']+)([?#][^\s\"']*)")
QPAIR_RX = re.compile(r"([?#&;][^=&;?#]*)=([^&;#?]*)")
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
EMAIL_OK = re.compile(r"(?i)noreply|no-reply|@example\.(?:com|org|net)$")
MAC_RX = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
ADSK_SERIAL_RX = re.compile(r"(?i)(serial(?:[ _]?(?:number|no))?|csn|sn|adlm_serial\w*)(\W{1,4})(?!000-00000000)"
                            r"(\d{3}-\d{8})(?!\d)")
VOL_RX = re.compile(r"(?i)(" + SEP + r"Volumes" + SEP + r")((?:" + _NOSEP + r"[^\\/\r\n\"'<>|*?:\t" + S_ANY + r"])+)")
MODEL_EXT = r"rvt|rfa|rte|rft|rvg|ifc|dwg|nwc|nwd"
_STEM = _NOSEP + r"[^\\/\[\]\"'=<>|\t:*?\r\n" + S_ANY + r"]"
MODEL_RX = re.compile(r"(^|[\\/\[\]\"'=<>|\t:*?" + S_ANY + r"]|%2[Ff]|%5[Cc])((?:" + _STEM + r")*?)(\.(?:" +
                      MODEL_EXT + r"))(?![A-Za-z0-9])", re.I | re.M)
# Autodesk templates and samples, Revit's default document names, our own smoke output: not personal
AUTODESK_STEMS = {
    "default", "defaultmetric", "defaultus-canada", "default_m_enu", "default_i_enu", "default-multi-discipline",
    "default-multi-discipline_metric", "default-multi-discipline_imperial", "architectural template",
    "construction template", "construction-default", "construction-defaultmetric", "structural analysis-default",
    "structural analysis-defaultmetric", "structural analysis-defaultus", "mechanical-default",
    "mechanical-defaultmetric", "electrical-default", "electrical-defaultmetric", "plumbing-default",
    "plumbing-defaultmetric", "systems-default", "systems-defaultmetric", "systems-default_metric",
    "rac_basic_sample_project", "rac_advanced_sample_project", "rac_basic_sample_family",
    "rme_basic_sample_project", "rme_advanced_sample_project", "rst_basic_sample_project",
    "rst_advanced_sample_project", "snowdon towers sample architectural", "snowdon towers sample structural",
    "snowdon towers sample hvac", "snowdon towers sample electrical", "snowdon towers sample plumbing",
    "snowdon towers sample site", "smoke", "smoke2",
}
AUTODESK_STEM_RX = re.compile(r"^(?:project|family|untitled)\d*$", re.I)

# Folders under the user's own roots become <DIR-n>: Wine's Documents/Desktop/Downloads (links to the Mac's), and the
# Mac home as ~ or CrossOver's Y: drive, except its standard folders
USER_FOLDERS = ("documents", "desktop", "downloads")
HOME_STANDARD = ("library", "applications", "movies", "music", "pictures", "public", ".trash")
SEP_RX = re.compile(SEP)
SEG_RX = re.compile(r"(?:" + _NOSEP + r"[^\\/\r\n\"'<>|*?\t\[\]:" + S_ANY + r"])+")
DIR_ROOT_RX = re.compile(r"(?i)(?:(?P<wine>(?<![^\W_])[a-z]:" + SEP + r"users" + SEP + r"crossover)|(?<![^\W_])y:|"
                         r"(?<![\w~])~|" + S_HOME + r")(?=" + SEP + r")")

# Anchored rules: they replace a value by its place, whatever its length
JRN_USER_RX = re.compile(r'(?i)(Jrn\.Directive[ \t]*(?:_[ \t]*\r?\n[ \t]*)?"Username"[ \t]*(?:_[ \t]*\r?\n[ \t]*)?,'
                         r'[ \t]*(?:_[ \t]*\r?\n[ \t]*)?")([^"\r\n]*)(")')
ATTR_USER_RX = re.compile(r"(?i)(Rvt\.Attr\.Username:[ \t]*)((?!Rvt\.)[^\s" + S_ANY + r"]+)")
INI_USER_RX = re.compile(r"(?im)^([ \t]*Username[ \t]*=[ \t]*)([^\r\n" + S_ANY + r"]*?)([ \t]*)(?=[\r\n]|\Z)")
INI_ID_RX = re.compile(r"(?im)^([ \t]*UserId[ \t]*=[ \t]*)([^\r\n" + S_ANY + r"]*?)([ \t]*)(?=[\r\n]|\Z)")
CONSENT_RX = re.compile(r"(?i)(UserConsent" + SEP + r")([A-Za-z0-9]{6,})(?=\.json)")
HOST_KEY_RX = re.compile(r"(?i)(\b(?:ComputerName|HOSTNAME)[ \t]*[=:][ \t]*\"?)([^\s\",;" + S_ANY + r"]+)")
HOST_FOUND_RX = re.compile(r"(?i)(found for host[ \t]+)([^\s:" + S_ANY + r"]+)")
USER_KEY_RX = re.compile(r"(?i)\b(USER|LOGNAME|LogonUser|USERNAME)([ \t]*[=:][ \t]*\"?)([^\r\n\",;" + S_ANY + r"]*"
                         r"[^\s\",;" + S_ANY + r"])")
OWNER_RX = re.compile(r"(?i)\b(RegOwner|RegCompany|COMPANYNAME|RegisteredOwner|RegisteredOrganization)"
                      r"([ \t]*[=:][ \t]*\"?)([^\r\n\"" + S_ANY + r"]*[^\s\"" + S_ANY + r"])")
BENIGN_USERS = ("crossover", "system", "root", "administrator", "default", "public")
# Words in these contexts are Autodesk's or font names, not the user's (letters-only values only)
EXEMPT_RX = re.compile(r"(?i)(?:program files(?: \(x86\))?" + SEP + r"autodesk" + SEP + r"|" + SEP + r"fonts" + SEP +
                       r")[^\r\n\"'<>|\t;,=()\[\]" + S_ANY + r"]*")

# ---- files: never opened, never a member ----
REFUSE_RX = re.compile(r"(?i)\.(dll|exe|msi|msp|cab|7z|rvt|rfa|rte|rft|rvg|dmp|reg|lic|dat|data|cxlog)$|"
                       r"LoginState\.xml|Local State|Cookies|\.DS_Store|journal\.\d+\.txt$")
NEVER_OPEN_RX = re.compile(r"(?i)Web Services|Identity Services|AdskLicensingService|ADPSDK|EBWebView|\.WebView2|"
                           r"QtWebEngine|LoginState|Local State|Cookies|Keychain|[\\/]tie[\\/]|\.lock\.owner|"
                           r"IndexedDB|Local Storage|Session Storage")
REFUSE_WHY = (("dll exe msi msp cab 7z", "a program or installer file: never included"),
              ("rvt rfa rte rft rvg", "a Revit model, family or template: never included"),
              ("dmp", "a crash dump: never included"), ("reg", "a registry file: never included"),
              ("lic dat data", "a license or data file: never included"),
              ("cxlog", "a whole Wine log: only a debug session's tail goes into a report"))


# ---------------------------------------------------------------------------------------------------------------
# Identity: learned at run time, kept in memory
# ---------------------------------------------------------------------------------------------------------------
class Identity:
    """The personal values report.py removes. They live in this object only: repr() shows counts, never a value."""

    def __init__(self):
        self.paths, self.words, self.homes = [], [], []
        self.login = None
        self.numbers = {k: {} for k in NUMBERED}   # value (lower case) -> number, in order of first appearance
        self.used = {k: set() for k in NUMBERED}
        self._rx = self._gate = None

    def __repr__(self):
        return "<Identity: %d paths, %d words>" % (len(self.paths), len(self.words))

    __str__ = __repr__

    def add_path(self, cls, p):
        p = os.path.normpath(p).rstrip("/") if p else ""
        if len(p) >= 4 and p.startswith("/") and (cls, p) not in self.paths:
            self.paths.append((cls, p))
            if cls == "home" and p not in self.homes:
                self.homes.append(p)
            self._rx = self._gate = None

    def add_word(self, cls, v):
        v = (v or "").strip()
        if not v or v.lower() == "crossover" or any(w.lower() == v.lower() for _, w in self.words):
            return
        self.words.append((cls, v))
        if cls in NUMBERED:
            self.numbers[cls].setdefault(v.lower(), len(self.numbers[cls]) + 1)
        self._rx = self._gate = None

    def number(self, kind, name):
        n = self.numbers[kind].setdefault(name.strip().lower(), len(self.numbers[kind]) + 1)
        self.used[kind].add(n)
        return n

    def token(self, cls, value):
        t = LABELS[cls][0]
        return t.format(self.number(cls, value)) if cls in NUMBERED else t

    def gate_values(self):
        """[(normalized value, class, 'path'|'word')] for the gate: paths in every root form, words of 3+ characters."""
        out = []
        for cls, p in self.paths:
            out.append((_normalize(p), cls, "path"))
            for h in self.homes:
                if p != h and p.startswith(h + "/"):
                    out.append(("~" + _normalize(p[len(h):]), cls, "path"))
                    out.append(("y:" + _normalize(p[len(h):]), cls, "path"))
        for cls, v in self.words:
            if len(v) >= 3:
                out.append((_normalize(v), cls, "word"))
        return out

    def gate_rx(self):
        if self._gate is None:
            self._gate = [(v, cls, kind, re.compile(re.escape(v) + END if kind == "path" else
                                                    r"(?<![^\W_])" + re.escape(v) + r"(?![^\W_])"))
                          for v, cls, kind in self.gate_values()]
        return self._gate

    def _compiled(self):
        if self._rx is None:
            paths = []
            for cls, p in sorted(self.paths, key=lambda cp: -len(cp[1])):
                for rx in _path_forms(p, self.homes):
                    paths.append((cls, re.compile(rx, re.I)))
            phases = {}
            for cls, v in self.words:
                if len(v) >= 3:
                    phases.setdefault(PHASE.get(cls, 3), {}).setdefault(v.lower(), cls)
            words = {p: (_word_rx(list(d)), d) for p, d in phases.items()}
            login = None
            if self.login:
                login = re.compile(r"(?i)(" + SEP + r"Users" + SEP + r")(" + re.escape(self.login) + r")" + END)
            self._rx = (paths, words, login)
        return self._rx


def _path_forms(p, homes):
    """Regexes for a POSIX path in every form a log gives it: Z:\\..., \\\\, \\/, %2F, file://, any case; under the home
    also as ~/... and CrossOver's Y:\\..."""
    body = "".join(SEP + re.escape(x) for x in p.split("/") if x)
    forms = [DRIVE + body + END]
    for h in homes:
        if p != h and p.startswith(h + "/"):
            tail = "".join(SEP + re.escape(x) for x in p[len(h):].split("/") if x)
            forms += [r"(?<![\w~])~" + tail + END, r"(?<![^\W_])[Yy]:" + tail + END]
    return forms


def _word_rx(values):
    alts = "|".join(re.escape(v) for v in sorted(values, key=lambda v: (-len(v), v)))
    return re.compile(r"(?<![^\W_])(?:" + alts + r")(?![^\W_])", re.I)


STOCK_HOSTS = ("mac", "macbook", "macbook-air", "macbook-pro", "imac", "mac-mini", "mac-studio", "mac-pro",
               "localhost")
DEFAULT_BOTTLE_RX = re.compile(r"^rvt\d{4}-[a-z0-9]{1,4}$", re.I)


def _as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else [x for x in v if x]


def _parts(v, min_len=3):
    return [p for p in re.split(r"[\s,.;:()+_@-]+", v or "") if len(p) >= min_len and not p.isdigit()]


def learn_identity(facts):
    """facts (dict, every key optional) -> Identity. Keys: login, gecos, home, data, root (a path or a list of
    paths), hosts (ComputerName, LocalHostName, HostName, hostname...), volumes, adsk_user, adsk_id, journal_user,
    serial, hw_uuid, macs, git_name, git_email, bottle, denylist."""
    ident = Identity()
    for cls, key in (("data", "data"), ("repo", "root"), ("home", "home")):
        for p in _as_list(facts.get(key)):
            ident.add_path(cls, p)
    login = (facts.get("login") or "").strip()
    if login:
        ident.login = login
        ident.add_word("user", login)
    gecos = (facts.get("gecos") or "").strip()
    if gecos and gecos.lower() != login.lower():
        ident.add_word("name", gecos)
        for p in _parts(gecos):
            ident.add_word("name", p)
    for h in _as_list(facts.get("hosts")):
        h = re.sub(r"(?i)\.local\.?$", "", h.strip())
        short = h.split(".")[0]
        for v in (h, short, short.upper()[:15]):   # Wine's ComputerName: upper case, the first 15 characters
            if v and v.lower() not in STOCK_HOSTS:
                ident.add_word("host", v)
    for v in _as_list(facts.get("volumes")):
        ident.add_word("volume", v)
    for key, cls in (("adsk_user", "adsk_user"), ("journal_user", "adsk_user"), ("adsk_id", "adsk_id")):
        for v in _as_list(facts.get(key)):
            ident.add_word(cls, v)
    for v in _as_list(facts.get("serial")):
        ident.add_word("serial", v)
    for v in _as_list(facts.get("hw_uuid")):
        ident.add_word("hw_uuid", v)
        ident.add_word("hw_uuid", v.replace("-", ""))
    for v in _as_list(facts.get("macs")):
        v = v.lower().replace("-", ":")
        if re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", v):
            for form in (v, v.replace(":", "-"), v.replace(":", "")):
                ident.add_word("mac", form)
    for v in _as_list(facts.get("git_name")):
        ident.add_word("name", v)
        for p in _parts(v):
            ident.add_word("name", p)
    for v in _as_list(facts.get("git_email")):
        ident.add_word("email", v)
        for p in _parts(v.split("@")[0]):
            ident.add_word("name", p)
    b = (facts.get("bottle") or "").strip()
    if b and not DEFAULT_BOTTLE_RX.match(b):
        ident.add_word("bottle", b)
    for v in _as_list(facts.get("denylist")):
        ident.add_word("private", v)
    return ident


def _run(cmd):
    exe = cmd[0]
    if not os.path.isabs(exe):
        exe = shutil.which(exe) or exe
    try:
        return subprocess.run([exe] + list(cmd[1:]), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=15, universal_newlines=True).stdout
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""


def _both(p):
    if not p:
        return []
    out = [os.path.abspath(p)]
    r = os.path.realpath(p)
    return out + ([r] if r not in out else [])


def _git_dir(root):
    g = os.path.join(root, ".git")
    if os.path.isdir(g):
        return g
    try:
        with open(g, encoding="utf-8") as f:
            m = re.match(r"gitdir:\s*(.+)", f.read().strip())
    except OSError:
        return None
    return os.path.join(root, m.group(1)) if m else None


def _denylist(root, data):
    """Extra words: DATA/.report-denylist and the clone's .git/info/denylist (the hooks' list); one per line, # starts a
    comment."""
    out, files = [], [os.path.join(data, ".report-denylist")]
    g = _git_dir(root)
    if g:
        files.append(os.path.join(g, "info", "denylist"))
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                out += [ln.strip() for ln in fh if ln.strip() and not ln.strip().startswith("#")]
        except OSError:
            pass
    return out


def _volumes():
    out = []
    try:
        names = os.listdir("/Volumes")
    except OSError:
        return out
    for n in names:
        if n.startswith((".", "com.apple")) or os.path.realpath(os.path.join("/Volumes", n)) == "/":
            continue   # the startup disk is a link to /
        out.append(n)
    return out


def machine_facts(root, data):
    """Facts of this Mac for learn_identity: reads the system (id, scutil, hostname, ioreg, ifconfig, git config)."""
    pw = pwd.getpwuid(os.getuid())
    f = {"login": pw.pw_name, "gecos": _run(["/usr/bin/id", "-F"]).strip() or pw.pw_gecos,
         "home": _both(os.environ.get("HOME")) + _both(pw.pw_dir), "data": _both(data), "root": _both(root)}
    f["hosts"] = [_run(["/usr/sbin/scutil", "--get", k]).strip() for k in ("ComputerName", "LocalHostName", "HostName")]
    f["hosts"] += [_run(["/bin/hostname"]).strip(), socket.gethostname()]
    f["volumes"] = _volumes()
    io = _run(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"])
    for key, name in (("serial", "IOPlatformSerialNumber"), ("hw_uuid", "IOPlatformUUID")):
        m = re.search(r'"' + name + r'"\s*=\s*"([^"]+)"', io)
        f[key] = m.group(1) if m else None
    f["macs"] = re.findall(r"^\s*ether\s+([0-9a-fA-F:]{17})\b", _run(["/sbin/ifconfig"]), re.M)
    if _git_dir(root):   # a clone: git is there (asking a Mac without it would offer to install the tools)
        f["git_name"] = _run(["git", "-C", root, "config", "user.name"]).strip()
        f["git_email"] = _run(["git", "-C", root, "config", "user.email"]).strip()
    f["denylist"] = _denylist(root, data)
    return f


def revit_ini_paths(bottle_dir, year):
    return [os.path.join(bottle_dir, "drive_c", "users", "crossover", "AppData", "Roaming", "Autodesk", "Revit",
                         "Autodesk Revit %s" % year, "Revit.ini"),
            os.path.join(bottle_dir, "drive_c", "ProgramData", "Autodesk", "RVT %s" % year, "UserDataCache",
                         "Revit.ini")]


def _regular(p):
    try:
        st = os.lstat(p)
    except OSError:
        return False
    return (st.st_mode & 0o170000) == 0o100000


def bottle_facts(bottle_dir, year):
    """The Autodesk identity Revit keeps in the bottle: Revit.ini [Partitions] Username and UserId, and the Username
    directive of the newest journal. Only these two files are opened, through bottleread."""
    f = {"adsk_user": [], "adsk_id": [], "journal_user": []}
    if not bottle_dir or not year:
        return f
    for p in revit_ini_paths(bottle_dir, year):
        if _regular(p):
            ini = bottleread.read_ini(p)
            f["adsk_user"].append(bottleread.ini_get(ini, "Partitions", "Username"))
            f["adsk_id"].append(bottleread.ini_get(ini, "Partitions", "UserId"))
    j = bottleread.newest_journal(bottle_dir, year)
    if j and _regular(j):
        head = "\n".join(itertools.islice(bottleread.read_lines(j), 3000))
        f["journal_user"] = [m.group(2) for m in JRN_USER_RX.finditer(head)]
    return f


def collect_identity(root, data, bottle_dir=None, year=None, bottle=None):
    """learn_identity over this Mac, the bottle and the denylists."""
    facts = machine_facts(root, data)
    facts.update(bottle_facts(bottle_dir, year))
    facts["bottle"] = bottle
    return learn_identity(facts)


# ---------------------------------------------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------------------------------------------
class _Text:
    def __init__(self, text):
        self.tokens, self.counts = [], collections.Counter()
        text = re.sub("[" + S_ANY + "]", "\ufffd", text)
        self.text = TOKEN.sub(lambda m: self.tok(m.group(0)), text)   # placeholders already there: kept, not counted

    def tok(self, token, cls=None):
        if cls:
            self.counts[cls] += 1
        if token == "~":
            return S_HOME
        self.tokens.append(token)
        return S_OPEN + "".join(chr(0xE100 + int(d)) for d in str(len(self.tokens) - 1)) + S_CLOSE

    def sub(self, rx, fn):
        self.text = rx.sub(fn, self.text)

    def done(self):
        t = S_RX.sub(lambda m: self.tokens[int("".join(str(ord(c) - 0xE100) for c in m.group(1)))], self.text)
        return t.replace(S_HOME, "~")


def _real(v):
    return bool(v) and not S_ONLY.fullmatch(v)


def _model(t, ident, m):
    stem = m.group(2)
    if not stem or stem[-1].isspace():
        return m.group(0)   # ".rvt files", "*.rvt": no name there
    core = stem.strip()
    if not core or core.lower() in AUTODESK_STEMS or AUTODESK_STEM_RX.match(core):
        return m.group(0)
    lead = stem[:len(stem) - len(stem.lstrip())]
    return m.group(1) + lead + t.tok("<MODEL-%d>" % ident.number("model", core), "model") + m.group(3)


def _dirs(t, ident):
    """Each folder under a user root -> <DIR-n>; the last part of a path keeps a short extension."""
    text, out, pos = t.text, [], 0
    for m in DIR_ROOT_RX.finditer(text):
        if m.start() < pos:
            continue
        wine = m.group("wine") is not None
        out.append(text[pos:m.end()])
        i, first = m.end(), True
        while True:
            s = SEP_RX.match(text, i)
            g = SEG_RX.match(text, s.end()) if s else None
            if not g:
                break
            seg, last = g.group(0), not SEP_RX.match(text, g.end())
            if first:
                first = False
                low = seg.strip().lower()
                if low in USER_FOLDERS and not last:
                    out.append(text[i:g.end()])
                    i = g.end()
                    continue
                if wine or low in HOME_STANDARD or low in USER_FOLDERS:
                    break
            name, rest = seg, ""
            if last:
                k = re.search(r"[,;=]", name)
                if k:
                    name, rest = name[:k.start()], name[k.start():]
                stripped = name.rstrip()
                name, rest = stripped, name[len(stripped):] + rest
                e = re.search(r"\.[A-Za-z0-9]{1,5}$", name)
                if e and e.start() > 0:
                    name, rest = name[:e.start()], name[e.start():] + rest
            if not name.strip():
                break
            out.append(text[i:s.end()] + t.tok("<DIR-%d>" % ident.number("dir", name), "dir") + rest)
            i = g.end()
            if last:
                break
        pos = i
    out.append(text[pos:])
    t.text = "".join(out)


def _words(t, ident, rx, classes):
    spans = [(m.start(), m.end()) for m in EXEMPT_RX.finditer(t.text)]
    starts = [s for s, _ in spans]

    def fn(m):
        v = m.group(0)
        if v.isalpha():
            i = bisect.bisect_right(starts, m.start()) - 1
            if i >= 0 and m.start() < spans[i][1]:
                return v
        cls = classes.get(v.lower()) or next(iter(classes.values()))
        return t.tok(ident.token(cls, v), cls)
    t.sub(rx, fn)


def _rel_forms(rel, ident):
    out = []
    for p in _both(rel):
        p = p.rstrip("/")
        for rx in _path_forms(p, ident.homes):
            out.append(re.compile(rx + r"(?:" + SEP + r")?", re.I))
    return out


def redact(text, identity, rel=None):
    """text with the learned values and known patterns replaced by placeholders -> (text, {class: count}).
    rel: a run folder whose paths become relative ("see rvt.log"). Running it again changes nothing."""
    t, ident = _Text(text), identity
    paths, words, login_rx = ident._compiled()
    if rel:
        for rx in _rel_forms(rel, ident):
            t.sub(rx, lambda m: "")
    for cls, rx in paths:   # DATA and REPO before the home (longer first), in POSIX, Z:, ~ and Y: forms
        t.sub(rx, lambda m, c=cls: t.tok(LABELS[c][0], c))
    t.sub(TMPDIR_RX, lambda m: t.tok("<TMPDIR>", "tmpdir"))
    t.sub(JWT_RX, lambda m: t.tok("<JWT>", "secret"))
    t.sub(BEARER_RX, lambda m: m.group(1) + t.tok("<SECRET>", "secret"))
    t.sub(CALLBACK_RX, lambda m: m.group(1) + t.tok("<CALLBACK>", "secret"))
    t.sub(KEYSECRET_RX, lambda m: m.group(1) + m.group(2) + t.tok("<SECRET>", "secret"))
    t.sub(URL_RX, lambda m: m.group(1) + QPAIR_RX.sub(
        lambda q: q.group(1) + "=" + (t.tok("<VALUE>", "query") if _real(q.group(2)) else q.group(2)), m.group(2)))
    t.sub(EMAIL_RX, lambda m: m.group(0) if EMAIL_OK.search(m.group(0)) else t.tok("<EMAIL>", "email"))
    t.sub(MAC_RX, lambda m: t.tok("<MAC-ADDR>", "mac"))
    t.sub(ADSK_SERIAL_RX, lambda m: m.group(1) + m.group(2) + t.tok("<SERIAL>", "adsk_serial"))
    t.sub(VOL_RX, lambda m: m.group(1) + t.tok(ident.token("volume", m.group(2)), "volume"))
    t.sub(MODEL_RX, lambda m: _model(t, ident, m))
    _dirs(t, ident)
    # the Autodesk identity, then the host, then the other words; anchored rules first, for values of any length
    for rx, cls in ((JRN_USER_RX, "adsk_user"), (INI_USER_RX, "adsk_user"), (INI_ID_RX, "adsk_id")):
        t.sub(rx, lambda m, c=cls: m.group(1) + (t.tok(LABELS[c][0], c) if _real(m.group(2)) else m.group(2)) +
              m.group(3))
    t.sub(ATTR_USER_RX, lambda m: m.group(1) + t.tok("<ADSK-USER>", "adsk_user"))
    t.sub(CONSENT_RX, lambda m: m.group(1) + t.tok("<ADSK-ID>", "adsk_id"))
    if 1 in words:
        _words(t, ident, *words[1])
    t.sub(HOST_KEY_RX, lambda m: m.group(1) + t.tok("<HOST>", "host"))
    t.sub(HOST_FOUND_RX, lambda m: m.group(1) + t.tok("<HOST>", "host"))
    if 2 in words:
        _words(t, ident, *words[2])
    if login_rx:
        t.sub(login_rx, lambda m: m.group(1) + t.tok("<USER>", "user"))

    def user_key(m):   # USERNAME = First Last: the whole value; USER=login more: the login only
        v, key = m.group(3), m.group(1).lower()
        if key in ("logonuser", "username") and v.lower() not in BENIGN_USERS and _real(v):
            return m.group(1) + m.group(2) + t.tok("<USER>", "user")
        first = v.split()[0]
        if ident.login and first.lower() == ident.login.lower():
            return m.group(1) + m.group(2) + t.tok("<USER>", "user") + v[len(first):]
        return m.group(0)
    t.sub(USER_KEY_RX, user_key)
    t.sub(OWNER_RX, lambda m: m.group(1) + m.group(2) + t.tok("<NAME>", "name"))
    if 3 in words:
        _words(t, ident, *words[3])
    return t.done(), dict(t.counts)


# ---------------------------------------------------------------------------------------------------------------
# The gate: independent of the redaction, fails closed
# ---------------------------------------------------------------------------------------------------------------
def _normalize(s):
    """Lower case; \\, \\\\, \\/ (JSON), %2F, %5C, file://, \\??\\ and \\\\?\\ all become one /."""
    s = s.lower().replace("file://", "/")
    s = re.sub(r"%2f|%5c", "/", s)
    s = re.sub(r"\\+", "/", s)
    s = re.sub(r"/+\?\?/|/+\?/", "/", s)
    return re.sub(r"/{2,}", "/", s)


GATE_RULES = (
    ("users-path", "path", re.compile(r"/users/(?!<|shared(?!\w)|public(?!\w)|crossover(?!\w))[^/\s\"'<>|]+")),
    ("volumes-path", "path", re.compile(r"/volumes/(?!<volume-\d+>)[^/\s\"'<>|]+")),
    ("jwt", "token", re.compile(r"eyj[a-z0-9_-]{8,}\.eyj[a-z0-9_-]{8,}\.[a-z0-9_-]{4,}")),
    ("bearer", "token", re.compile(r"\bbearer\s+(?!<)[a-z0-9._~+/=-]{8,}")),
    ("callback", "token", re.compile(r"adskidmgr:[^\s]*code=")),
    ("secret", "token", re.compile(r"\b(?:access_token|refresh_token|id_token|client_secret|code_verifier|password|"
                                   r"passwd)[\"']?\s{0,2}[=:]\s{0,2}[\"']?(?!<)[^\s\"'&,;<>]{6,}")),
    ("mac-address", "address", re.compile(r"(?<![0-9a-f:-])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f:-])")),
    ("serial", "serial", re.compile(r"(?:serial|csn)\W{1,4}(?!000-00000000)\d{3}-\d{8}")),
    ("journal-username", "adsk_user", re.compile(r'"username"[\s_]*,[\s_]*"(?!<adsk-user>"|")')),
    ("ini-user", "adsk_user", re.compile(r"(?m)^[ \t]*user(?:name|id)[ \t]*=[ \t]*(?!<|crossover\b)[^\s]")),
)
GATE_EMAIL = re.compile(r"[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}")
GATE_URL = re.compile(r"\bhttps?:/+[^\s?#\"']+([?#][^\s\"']*)")
GATE_MODEL = re.compile(r"\.(?:" + MODEL_EXT + r")(?![a-z0-9])")
GATE_STEM = re.compile(r"[^/\[\]\"'=<>|\t:*?\r\n]*$")
GATE_DIR_ROOT = re.compile(r"(?:(?P<wine>(?<![^\W_])[a-z]:/users/crossover)|(?<![^\W_])y:|(?<![\w~])~)(?=/)")
GATE_SEG = re.compile(r"[^/\r\n\"'<>|*?\t\[\]:]+")
GATE_EXEMPT = re.compile(r"(?:program files(?: \(x86\))?/autodesk/|/fonts/)[^\r\n\"'<>|\t;,=()\[\]]*")


def _gate_text(norm, ident, name):
    nl = [m.start() for m in re.finditer("\n", norm)]
    hits = []

    def hit(rule, cls, pos, length):
        hits.append({"rule": rule, "file": name, "line": bisect.bisect_left(nl, pos) + 1, "class": cls,
                     "length": length})
    for rule, cls, rx in GATE_RULES:
        for m in rx.finditer(norm):
            hit(rule, cls, m.start(), len(m.group(0)))
    for m in GATE_EMAIL.finditer(norm):
        if not EMAIL_OK.search(m.group(0)):
            hit("email", "email", m.start(), len(m.group(0)))
    for m in GATE_URL.finditer(norm):
        for q in QPAIR_RX.finditer(m.group(1)):
            v = q.group(2)
            if v and not TOKEN.fullmatch(v):
                hit("url-query", "token", m.start(), len(v))
    for m in GATE_MODEL.finditer(norm):
        before = norm[max(0, m.start() - 400):m.start()]
        if re.search(r"<model-\d+>$", before):
            continue
        stem = GATE_STEM.search(before).group(0)
        if not stem or stem[-1].isspace():
            continue
        core = stem.strip()
        if core and core not in AUTODESK_STEMS and not AUTODESK_STEM_RX.match(core):
            hit("model-file", "model", m.start(), len(core))
    for m in GATE_DIR_ROOT.finditer(norm):
        wine, i, first = m.group("wine") is not None, m.end(), True
        while norm.startswith("/", i):
            tk = TOKEN.match(norm, i + 1)
            if tk:
                i, first = tk.end(), False
                continue
            g = GATE_SEG.match(norm, i + 1)
            if not g:
                break
            seg, last = g.group(0), not norm.startswith("/", g.end())
            if first:
                first = False
                low = seg.strip()
                if low in USER_FOLDERS and not last:
                    i = g.end()
                    continue
                if wine or low in HOME_STANDARD or low in USER_FOLDERS:
                    break
            hit("user-dir", "path", i + 1, len(seg))
            break
    if ident is not None:
        blank = TOKEN.sub("<>", norm)   # a value that is also a placeholder's word (user, model...) is not a hit
        bnl = [m.start() for m in re.finditer("\n", blank)]
        spans = [(m.start(), m.end()) for m in GATE_EXEMPT.finditer(blank)]
        starts = [s for s, _ in spans]
        for value, cls, kind, rx in ident.gate_rx():
            for m in rx.finditer(blank):
                if kind == "word" and value.isalpha():
                    j = bisect.bisect_right(starts, m.start()) - 1
                    if j >= 0 and m.start() < spans[j][1]:
                        continue
                hits.append({"rule": "learned", "file": name, "line": bisect.bisect_left(bnl, m.start()) + 1,
                             "class": cls, "length": len(value)})
    return hits


def gate(data, identity=None, name=""):
    """Hits of the independent check in one text or file content: learned values in any form, and rules that need no
    learned value. data: bytes (read as UTF-8 and as UTF-16LE) or str -> [{rule, file, line, class, length}].
    A hit never holds the value or any part of it."""
    views = [data] if isinstance(data, str) else [data.decode("utf-8", "replace")]
    if isinstance(data, bytes) and len(data) >= 2:
        views += [data.decode("utf-16-le", "ignore"), data[1:].decode("utf-16-le", "ignore")]
    seen, out = set(), []
    for v in views:
        for h in _gate_text(_normalize(v), identity, name):
            k = (h["rule"], h["line"], h["class"], h["length"])
            if k not in seen:
                seen.add(k)
                out.append(h)
    return out


def hit_line(h):
    return "%s\t%s\t%s\t%s\t%s" % (h["rule"], h["file"], h["line"], h["class"], h["length"])


# ---------------------------------------------------------------------------------------------------------------
# Extracts: by allowlist, never a whole file
# ---------------------------------------------------------------------------------------------------------------
JRN_TS = re.compile(r"^\s*'[A-Z] (\d{1,2}-[A-Za-z]{3}-\d{4} \d\d:\d\d:\d\d\.\d{3});")
JRN_FAIL = re.compile(r"(?i)error|exception|fail|crash|unrecoverable|assert|captureTryCrash|does not answer|"
                      r"not responding|fatal|unconverted")
JRN_MARKERS = re.compile(r"started recording journal file|finished recording journal file|Delayed start|"
                         r"appPriv idle|Journal Init")
JRN_DROP = re.compile(r"(?i)found for host|ip address|docsymbol|globaltoproj|projtopage|this: \[")
JRN_KEEP_DIRECTIVES = ("version", "debugmode", "screenresolution")
JRN_ID = re.compile(r"^(?:ID_[A-Z0-9_]+|[A-Z0-9_]{3,})$")


def _statements(lines):
    """Journal lines -> (first line number, [lines]) per statement: a Jrn.* line with its '_' continuations, or one
    other line."""
    cur, start = None, 0
    for i, line in enumerate(lines, 1):
        if cur is not None:
            cur.append(line)
            if not line.rstrip().endswith("_"):
                yield start, cur
                cur = None
            continue
        if re.match(r"^\s*Jrn\.", line) and line.rstrip().endswith("_"):
            cur, start = [line], i
            continue
        yield i, [line]
    if cur is not None:
        yield start, cur


def _joined(st):
    return " ".join(re.sub(r"\s*_\s*$", "", s.strip()) for s in st)


def journal_extract(lines, keep=None):
    """The allowed lines of a Revit journal: Build/Release, directives Version/DebugMode/ScreenResolution, command ids,
    TaskDialog ids, license state, start/end markers and lines that report a failure (keep: an extra regex, e.g. the
    signature catalog). Everything else becomes '... N lines dropped'; add-in lines become a count."""
    out, dropped, addins, errors, vendors = [], 0, 0, 0, set()

    def put(s):
        nonlocal dropped
        if dropped:
            out.append("\u2026 %d lines dropped" % dropped)
            dropped = 0
        out.append(s)
    for _, st in _statements(lines):
        one = st[0]
        n = len(st)
        ts = JRN_TS.match(one)
        stamp = ("'%s %s; " % (one.strip()[1], ts.group(1))) if ts else ""
        code = re.match(r"^\s*Jrn\.(\w+)", one)
        if code:
            j = _joined(st)
            kind = code.group(1).lower()
            q = re.findall(r'"([^"]*)"', j)
            if kind == "command":
                ids = re.findall(r',\s*([A-Za-z_][A-Za-z0-9_]*)\s*"', j)
                cid = ids[-1] if ids and JRN_ID.match(ids[-1]) else "(id not kept)"
                src = q[0] if q and re.fullmatch(r"[A-Za-z]+", q[0]) else "?"
                put('Jrn.Command "%s" %s' % (src, cid))
            elif kind == "directive" and q and q[0].lower() in JRN_KEEP_DIRECTIVES:
                put(re.sub(r"\s+", " ", j))
            elif kind == "data" and q and q[0] == "TaskDialogResult" and re.fullmatch(r"ID[A-Z]+", q[-1]):
                put('Jrn.Data "TaskDialogResult" %s' % q[-1])
            else:
                dropped += n
            continue
        s = one
        if re.match(r"^\s*' (Build|Release):\s*[\w.() -]+$", s):
            put(s.strip())
        elif re.search(r"\bAPI_\w+\s*\{", s):
            addins += 1
            errors += "API_ERROR" in s
            vendors.update(v.upper() for v in re.findall(r"VendorId\(\s*([A-Za-z]+)\s*\)", s)
                           if v.upper() in ("ADSK", "AUTODESK"))
            dropped += 1
        elif re.match(r"^\s*'\s*Id\s*:\s*TaskDialog_[A-Za-z0-9_]+\s*$", s):
            put("'Id : " + re.search(r"TaskDialog_[A-Za-z0-9_]+", s).group(0))
        elif re.match(r"^\s*'(CommonButtons|DefaultButton)\s*:\s*[A-Za-z, ]*$", s):
            put(s.strip())
        elif re.search(r"0:<\s*TaskDialog\b", s):
            put(stamp + "0:< TaskDialog (text dropped)")
        elif "Rvt.Attr.MessageId:" in s:
            mid = re.search(r"Rvt\.Attr\.MessageId:\s*([A-Za-z0-9_]+)", s)
            ans = re.search(r"Rvt\.Attr\.MessageAnswer:\s*(ID[A-Z]+)", s)
            put("' MessageId: %s%s" % (mid.group(1) if mid else "?", " MessageAnswer: " + ans.group(1) if ans else ""))
        elif re.search(r"License mode:\s*[A-Za-z]+", s):
            put(stamp + "0:< License mode: " + re.search(r"License mode:\s*([A-Za-z]+)", s).group(1))
        elif "License initialization complete" in s:
            put(stamp + "0:< License initialization complete")
        elif "manage licensing" in s:
            rest = s.split("manage licensing", 1)[1].strip()
            put(stamp + "0:< manage licensing" + (" " + rest if re.fullmatch(r"[A-Za-z \-]*", rest) else ""))
        elif re.search(r"(?i)license will expire in \d+ days", s):
            days = int(re.search(r"(?i)expire in (\d+) days", s).group(1))
            put(stamp + "0:< license expiry: " + ("7 days or less" if days <= 7 else "ok"))
        elif re.search(r"(?i)\bExpiration:", s) or JRN_DROP.search(s):
            dropped += 1
        elif JRN_MARKERS.search(s):
            put(stamp + JRN_MARKERS.search(s).group(0))
        elif ("0:<" in s or ts) and (JRN_FAIL.search(s) or (keep is not None and keep.search(s))):
            mark = re.match(r"^\s*'[A-Z]?", s).group(0)   # quoted and bracketed text can be a document or view title
            rest = re.sub(r"\[[^\]]*\]", "[…]", re.sub(r"'[^'\n]*'", "'…'", re.sub(r'"[^"]*"', '"…"',
                                                                                           s[len(mark):])))
            put((mark + rest).strip())
        else:
            dropped += 1
    if dropped:
        out.append("\u2026 %d lines dropped" % dropped)
    if addins:
        out.append("add-in lines: %d (%d errors); Autodesk vendor ids: %s" % (addins, errors,
                                                                             ", ".join(sorted(vendors)) or "none"))
    if len(out) > JOURNAL_MAX:
        head = [s for s in out[:60] if s.startswith(("' Build", "' Release", "Jrn.Directive"))]
        out = head + ["\u2026 %d kept lines cut" % (len(out) - JOURNAL_MAX)] + out[-JOURNAL_MAX:]
    return out


MSI_FAIL = re.compile(r"Return value 3\b")
MSI_ERR = re.compile(r"\bError \d{4}\b|returned actual error code")
MSI_PROP = re.compile(r"^\s*Property\(([A-Z])\):\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=")
MSI_KEEP = ("productversion", "productcode", "adlm_prodkey", "revitlanguage", "transforms")


def msi_extract(lines, before=MSI_BEFORE, windows=MSI_WINDOWS):
    """An MSI log, never its tail: the lines before each 'Return value 3' (at most `windows` windows), lines with an
    error code, and the allowed properties. Every other Property(S|C) line is dropped. [] when nothing failed."""
    out, props, buf, n_win, n_err, last = [], collections.OrderedDict(), collections.deque(maxlen=before), 0, 0, 0
    for i, line in enumerate(lines, 1):
        m = MSI_PROP.match(line)
        if m:
            if m.group(2).lower() in MSI_KEEP:
                props.setdefault(m.group(2).lower(), line.strip())
            continue
        if MSI_FAIL.search(line) and n_win < windows:
            n_win += 1
            shown = [ln for j, ln in buf if j > last]
            out.append('--- %d lines before "Return value 3" (line %d) ---' % (len(shown), i))
            out += shown + [line]
            last = i
            buf.clear()
            continue
        if MSI_ERR.search(line) and n_err < 50:
            n_err += 1
            out.append(line)
            last = i
        buf.append((i, line))
    if not out:
        return []
    if props:
        out.append("--- properties ---")
        out += list(props.values())
    return out


CX_HEADER = re.compile(r"^\*{2,5} \w{3} \w{3} +\d+ \d\d:\d\d:\d\d \d{4}")
CX_WINE = re.compile(r"^(?:\d+\.\d+:)?[0-9a-f]{4}:(?:[0-9a-f]{4}:)?(?:err|warn|fixme|trace|info|Call|Ret):|^wine: |"
                     r"^\d+\.\d+:[0-9a-f]{4}:")
CX_HEADERISH = re.compile(r"^\*{2,5} |^Starting|^Command:|^CXConfig->|^Environment:|^\s+[A-Z][A-Z0-9_]+ = |"
                          r"^\d+: (?:Grabbing|Got|Releasing) the '|^Product version=|^Mode = ")
CX_FIELDS = (("Product version", re.compile(r"^Product version\s*=\s*([0-9.]+)\s*$")),
             ("Mode", re.compile(r"^Mode\s*=\s*'?([A-Za-z0-9_-]+)'?\s*$")),
             ("backend", re.compile(r'^\s+CX_GRAPHICS_BACKEND\s*=\s*"?([A-Za-z0-9_-]+)"?\s*$')),
             ("CX_DEBUGMSG", re.compile(r'^\s+CX_DEBUGMSG\s*=\s*"([A-Za-z0-9_+\-,.:]*)"\s*$')),
             ("WINEDEBUG", re.compile(r'^\s+WINEDEBUG\s*=\s*"([A-Za-z0-9_+\-,.:]*)"\s*$')))
CX_PATH = re.compile(r'^\s+PATH\s*=\s*"(.*)"\s*$')
GAP = object()   # cxlog_file: the lines between the head and the tail were not read


def cxlog_extract(lines, tail=TAIL):
    """A CrossOver log: never its header (Environment, CXConfig->read, Starting/Command), only fields of the newest
    header (CrossOver version, mode, backend, debug channels, PATH as a count), then the last `tail` lines without
    header lines."""
    fields, sessions, state, buf = {}, 0, "start", collections.deque(maxlen=tail)
    for line in lines:
        if line is GAP:
            state = "unknown"
            buf.append((False, None))
            continue
        if CX_HEADER.match(line) or (state == "start" and CX_HEADERISH.match(line)):
            state, fields = "header", {}
            sessions += 1
        elif state == "header" and CX_WINE.match(line):
            state = "body"
        elif state == "start":
            state = "body"
        is_head = state == "header" or (state == "unknown" and bool(CX_HEADERISH.match(line)))
        if state == "header":
            for k, rx in CX_FIELDS:
                m = rx.match(line)
                if m:
                    fields[k] = m.group(1)
            m = CX_PATH.match(line)
            if m:
                fields["PATH"] = "%d entries" % len([p for p in m.group(1).split(":") if p])
        buf.append((is_head, line))
    out = ["wine.cxlog: %d session%s; header fields of the newest:" % (sessions, "" if sessions == 1 else "s")]
    fields.setdefault("backend", "default")
    for k in ("Product version", "Mode", "backend", "CX_DEBUGMSG", "WINEDEBUG", "PATH"):
        if k in fields:
            out.append("  %s: %s" % (k, fields[k]))
    out.append("Last %d lines (header lines left out):" % tail)
    skipped = 0
    for is_head, line in buf:
        if is_head:
            skipped += 1
            continue
        if skipped:
            out.append("\u2026 %d header lines left out" % skipped)
            skipped = 0
        out.append("\u2026" if line is None else line)
    if skipped:
        out.append("\u2026 %d header lines left out" % skipped)
    return out


# ---- reading logs: UTF-8 or UTF-16, binary-safe, bounded ----
def _is_utf16(head):
    if head.startswith((b"\xff\xfe", b"\xfe\xff")):
        return True
    s = head[:512]
    return len(s) >= 4 and s[1::2].count(0) > len(s) // 4 and s[0::2].count(0) < len(s) // 8


def _utf16_lines(path, max_bytes=64 << 20):
    with open(path, "rb") as f:
        raw = f.read(max_bytes)
    text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-16-le", "replace")
    return [ln[:4000] for ln in text.splitlines()]


def _lines(path, max_bytes=None):
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
    except OSError:
        return iter(())
    if _is_utf16(head):
        return iter(_utf16_lines(path))
    return bottleread.read_lines(path, max_bytes)


def _tail(path, n):
    """The last n lines of a file that may be huge -> (lines, cut: whether there were more)."""
    try:
        f = open(path, "rb")
    except OSError:
        return [], False
    with f:
        head = f.read(4096)
        if _is_utf16(head):
            lines = _utf16_lines(path)
            return lines[-n:], len(lines) > n
        size = os.fstat(f.fileno()).st_size
        win = 1 << 20
        while True:
            start = max(0, size - win)
            f.seek(start)
            data = f.read(size - start)
            if start > 0:
                data = data[data.find(b"\n") + 1:]
            lines = data.split(b"\n")
            if lines and lines[-1] == b"":
                lines.pop()
            if len(lines) > n or start == 0 or win >= 32 << 20:
                break
            win *= 4
    out = [ln.decode("utf-8", "replace").rstrip("\r")[:4000] for ln in lines[-n:]]
    return out, start > 0 or len(lines) > n


def cxlog_file(path, tail=TAIL):
    """cxlog_extract for a file: a big log is read at its start (the header) and its end only."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return []
    if size <= 8 << 20:
        return cxlog_extract(_lines(path), tail)
    end, _ = _tail(path, tail + 60)
    return cxlog_extract(itertools.chain(itertools.islice(_lines(path), 600), [GAP], end), tail)


def _text(path, keep="head", limit=MEMBER_MAX * 2):
    lines = list(_lines(path)) if keep == "head" else _tail(path, 100000)[0]
    text = "\n".join(lines)
    return text[:limit] if keep == "head" else text[-limit:]


# ---------------------------------------------------------------------------------------------------------------
# Building the report
# ---------------------------------------------------------------------------------------------------------------
RUN_RE = re.compile(r"^(\d{8}-\d{6})(?:-(\d+))?-([a-z]+)$")
KIND_LABEL = {"install": "install log", "steps": "steps log", "addins": "add-ins log", "debug": "debug session",
              "test": "test run"}
ACTIONS = ("shims", "revit", "redist", "unpack", "bottle", "steps", "apps")
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")


def _listdir(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


def _why_not(name, path):
    if os.path.islink(path):
        return "a link: never followed"
    if os.path.isdir(path):
        return "a folder: not read"
    if NEVER_OPEN_RX.search(name) or name in ("LoginState.xml", "Cookies", "Local State"):
        return "sign-in, licensing or browser data: never opened"
    if re.search(r"(?i)journal\.\d+\.txt$", name):
        return "a whole Revit journal: never included"
    if name == ".DS_Store":
        return "Finder data: never included"
    m = REFUSE_RX.search(name)
    if m and m.group(1):
        for exts, why in REFUSE_WHY:
            if m.group(1).lower() in exts.split():
                return why
    return "not needed for a report"


def _folder_time(d):
    m = RUN_RE.match(os.path.basename(d))
    if m:
        try:
            return time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S"))
        except (ValueError, OverflowError):
            pass
    try:
        return os.path.getmtime(d)
    except OSError:
        return None


def _runs(data, bottle):
    logs = os.path.join(data, "logs")
    out = []
    for n in ([bottle] if bottle else _listdir(logs)):
        d = os.path.join(logs, n)
        if n == "runs" or os.path.islink(d) or not os.path.isdir(d):
            continue
        for r in _listdir(d):
            m, p = RUN_RE.match(r), os.path.join(d, r)
            if m and m.group(3) in KIND_LABEL and os.path.isdir(p) and not os.path.islink(p):
                out.append(((m.group(1), int(m.group(2) or 1)), m.group(3), p))
    return out


def _pick(runs):
    newest = {}
    for key, kind, p in runs:
        if kind not in newest or key > newest[kind][0]:
            newest[kind] = (key, p)
    out, inst = [], newest.get("install")
    if inst:
        out.append(("install", inst[1]))
    for kind in ("steps", "addins"):
        if kind in newest and (not inst or newest[kind][0] > inst[0]):
            out.append((kind, newest[kind][1]))
    for kind in ("debug", "test"):
        if kind in newest:
            out.append((kind, newest[kind][1]))
    return out


class _Collect:
    def __init__(self, data, now):
        self.data, self.now = data, now
        self.items, self.skipped, self.facts = [], [], {"ages": [], "doctor": None, "last": None}

    def label(self, p):
        a, b = os.path.abspath(p), os.path.abspath(self.data)
        return os.path.relpath(a, b) if a.startswith(b + "/") else os.path.basename(a)

    def add(self, name, what, text, src=None, keep="tail", rel=None, cut=None, age=None):
        self.items.append({"name": name, "what": what, "text": text, "src": src, "keep": keep, "rel": rel,
                           "cut": cut, "age": age})


def _failed_steps(d):
    out = []
    p = os.path.join(d, "failed.txt")
    if _regular(p):
        for ln in _lines(p):
            s = ln.strip()
            if SAFE_NAME.match(s) and s not in out:
                out.append(s)
    return out


def _failed_actions(d):
    out = []
    p = os.path.join(d, "summary.txt")
    if _regular(p):
        for ln in _lines(p):
            m = re.match(r"^\s+(\S+)\s+exit=(\S+)", ln)
            if m and m.group(1) in ACTIONS and m.group(2) not in ("0", "skip") and m.group(1) not in out:
                out.append(m.group(1))
    return out


def _take_run(c, d, kind):
    used, label = set(), KIND_LABEL.get(kind, "log")
    age = (label, _folder_time(d))

    def take(fname, name, what, text, keep="tail", cut=None):
        used.add(fname)
        c.add(name, what, text, src=c.label(os.path.join(d, fname)), keep=keep, rel=d, cut=cut, age=age)
    if kind in ("install", "steps", "addins"):
        for f in ("summary.txt", "failed.txt"):
            if _regular(os.path.join(d, f)):
                take(f, "%s/%s" % (kind, f), "%s of the %s" % (f, label), _text(os.path.join(d, f)), keep="head")
        failed = _failed_steps(d)
        c.facts.setdefault("failed", {})[kind] = failed
        for s in failed + ["action-" + a for a in _failed_actions(d)]:
            f = s + ".log"
            if _regular(os.path.join(d, f)):
                lines, cut = _tail(os.path.join(d, f), TAIL)
                take(f, "%s/%s" % (kind, f), "tail of %s" % f, "\n".join(lines),
                     cut="to its last %d lines" % TAIL if cut else None)
        for f in _listdir(d):
            if f.endswith(".msi.log") and SAFE_NAME.match(f) and _regular(os.path.join(d, f)):
                ex = msi_extract(_lines(os.path.join(d, f)))
                if ex:
                    take(f, "%s/%s-errors.txt" % (kind, f[:-len(".msi.log")]), "error windows of %s" % f,
                         "\n".join(ex), cut="to its error windows")
                else:
                    used.add(f)
                    c.skipped.append((c.label(os.path.join(d, f)), "an MSI log without a failure: nothing to add"))
    elif kind == "debug":
        p = os.path.join(d, "wine.cxlog")
        if _regular(p):
            take("wine.cxlog", "debug/wine-cxlog.txt", "header fields and tail of wine.cxlog",
                 "\n".join(cxlog_file(p)), cut="to its header fields and last %d lines" % TAIL)
        p = os.path.join(d, "stdout.log")
        if _regular(p):
            lines, cut = _tail(p, 100)
            take("stdout.log", "debug/stdout.log", "tail of stdout.log", "\n".join(lines),
                 cut="to its last 100 lines" if cut else None)
    elif kind == "test":
        p = os.path.join(d, "result.json")
        if _regular(p):
            take("result.json", "test/result.json", "result of the test run", _text(p), keep="head")
    for f in _listdir(d):
        if f not in used:
            c.skipped.append((c.label(os.path.join(d, f)), _why_not(f, os.path.join(d, f))))


def _ini_allowed(path):
    ini = bottleread.read_ini(path)
    out = []
    for sec, keys in ini.items():
        for k, v in keys.items():
            if (sec.lower() == "graphics" or (sec.lower(), k.lower()) in (("language", "select"),
                                                                          ("system", "useidsdk"))):
                ok = re.fullmatch(r"[A-Za-z0-9 ._-]{0,40}", v)
                out.append("[%s] %s=%s" % (sec, k, v if ok else "(not shown)"))
    return out


def _collect(root, data, bdir, year, bottle, run, doctor_json, now):
    c = _Collect(data, now)
    if doctor_json:
        try:
            with open(doctor_json, encoding="utf-8", errors="replace") as f:
                text = f.read(MEMBER_MAX * 2)
            c.facts["doctor"] = json.loads(text)
        except (OSError, ValueError):
            text = None
        if text:
            c.add("doctor.json", "./revit doctor checks", text, keep="head")
    folders = []
    if run:
        rp = os.path.abspath(run)
        res = os.path.join(rp, "result")
        if _regular(res):
            text = _text(res)
            c.add("run/result.txt", "result of the run", text, src=c.label(res), keep="head")
            ev = os.path.join(rp, "events.ndjson")
            if _regular(ev):
                lines, cut = _tail(ev, 300)
                c.add("run/events.ndjson", "events of the run", "\n".join(lines), src=c.label(ev),
                      cut="to its last 300 lines" if cut else None)
            m = re.search(r"(?m)^log_dir=(.+)$", text)
            if m and os.path.isdir(m.group(1).strip()) and not os.path.islink(m.group(1).strip()):
                rp = m.group(1).strip()
            else:
                rp = None
        if rp:
            m = RUN_RE.match(os.path.basename(rp))
            kind = m.group(3) if m and m.group(3) in KIND_LABEL else (
                "debug" if os.path.exists(os.path.join(rp, "wine.cxlog")) else
                "test" if os.path.exists(os.path.join(rp, "result.json")) else "install")
            folders.append((kind, rp))
    else:
        folders = _pick(_runs(data, bottle))
    logs = os.path.realpath(os.path.join(data, "logs"))
    for kind, d in folders:   # a run folder is under DATA/logs, or it is not read at all
        if os.path.realpath(d).startswith(logs + "/") and not NEVER_OPEN_RX.search(os.path.abspath(d)):
            _take_run(c, d, kind)
        else:
            c.skipped.append((os.path.basename(d.rstrip("/")), "a folder outside the log folder: not read"))
    c.facts["kinds"] = [k for k, _ in folders]
    if bdir:
        rn = os.path.join(bdir, "revit-macos", "runs.ndjson")
        if _regular(rn):
            lines, cut = _tail(rn, 2000)
            c.add("bottle/runs.ndjson", "run records of the bottle", "\n".join(lines), src="bottle: runs.ndjson",
                  cut="to its last 2000 records" if cut else None)
            for ln in reversed(lines):
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("kind") == "install":
                    c.facts["last"] = r
                    break
        if year:
            p = revit_ini_paths(bdir, year)[0]
            if _regular(p):
                allowed = _ini_allowed(p)
                if allowed:
                    c.add("bottle/revit-ini.txt", "allowed keys of Revit.ini", "\n".join(allowed),
                          src="bottle: Revit.ini", keep="head")
            j = bottleread.newest_journal(bdir, year)
            if j and _regular(j):
                ex = journal_extract(bottleread.read_lines(j))
                for s in ex[:80]:
                    m = re.match(r"^' (Build|Release):\s*(.+)$", s)
                    if m:
                        c.facts[m.group(1).lower()] = m.group(2).strip()
                c.add("bottle/journal-extract.txt", "extract of the newest Revit journal", "\n".join(ex),
                      src="bottle: newest Revit journal", cut="to its allowed lines",
                      age=("Revit journal", os.path.getmtime(j)))
    return c


def _caps(text, keep):
    """Lines of at most LINE_MAX characters, at most MEMBER_MAX bytes (the head or the tail) -> (bytes, cut)."""
    cut, lines = None, []
    for ln in text.split("\n"):
        if len(ln) > LINE_MAX:
            ln, cut = ln[:LINE_MAX - 7] + " \u2026[cut]", "long lines cut"
        lines.append(ln)
    data = "\n".join(lines).encode("utf-8")
    if len(data) > MEMBER_MAX:
        if keep == "head":
            data = data[:MEMBER_MAX].rsplit(b"\n", 1)[0] + "\n\u2026 (cut to 256 KB)".encode("utf-8")
        else:
            data = "\u2026 (cut to the last 256 KB)\n".encode("utf-8") + data[-MEMBER_MAX:].split(b"\n", 1)[-1]
        cut = "cut to 256 KB"
    return data, cut


def _refused(name, data):
    if REFUSE_RX.search(name):
        return "a binary or private file type"
    if data and data.count(b"\0") > len(data) * NUL_MAX:
        return "it is not a text file"
    return None


def _age(sec):
    d = int(sec // 86400)
    return "today" if d <= 0 else "1 day old" if d == 1 else "%d days old" % d


def _summary(counts, ident):
    parts = []
    for cls in ORDER:
        if cls in NUMBERED:
            n = len(ident.used[cls])
            if n:
                parts.append("%d %s%s" % (n, LABELS[cls][1], "" if n == 1 else "s"))
        elif counts.get(cls):
            parts.append("%s %s\u00d7" % (LABELS[cls][1], "{:,}".format(counts[cls])))
    return "Replaced: " + (", ".join(parts) if parts else "nothing")


def _crossover():
    cx = os.environ.get("REVIT_CX") or "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
    try:
        with open(os.path.join(cx, "..", "..", "Info.plist"), "rb") as f:
            p = plistlib.load(f)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return "not found"
    v, b = p.get("CFBundleShortVersionString"), p.get("CFBundleVersion")
    return "%s (%s)" % (v, b) if v and b and b != v else (v or b or "unknown")


def _engine(root):
    ab = os.path.join(root, ".app-bundle")
    if os.path.isfile(ab):
        try:
            with open(ab, encoding="utf-8") as f:
                m = re.search(r"(?m)^app_version=(.+)$", f.read())
            return "app:" + m.group(1).strip() if m else "app"
        except OSError:
            return "app"
    if not _git_dir(root):
        return "unknown"
    sha = _run(["git", "-C", root, "rev-parse", "--short", "HEAD"]).strip()
    if not sha:
        return "unknown"
    dirty = _run(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"]).strip()
    return "git:" + sha + ("+dirty" if dirty else "")


def _report_text(c, root, year, bottle, kept, left, counts, ident, now, manifest_left):
    f = c.facts
    sfx = " " + bottle if bottle and year and bottle != "rvt%s-a" % year else ""
    out = ["revit-macos report", "Made: %s UTC" % time.strftime("%Y-%m-%d %H:%M", time.gmtime(now))]
    out.append("Revit: %s" % ("%s, bottle %s" % (year, bottle) if year and bottle else year or "no year given"))
    out.append("Mac: macOS %s, %s" % (platform.mac_ver()[0] or "unknown", platform.machine()))
    out.append("CrossOver: %s" % _crossover())
    out.append("This project: %s" % _engine(root))
    if f.get("build"):
        out.append("Revit build (newest journal): %s%s" % (f["build"], ", release " + f["release"]
                                                          if f.get("release") else ""))
    out.append("")
    doc = f.get("doctor")
    checks = doc.get("checks") if isinstance(doc, dict) else None
    if isinstance(checks, list):
        probs = [x for x in checks if isinstance(x, dict) and x.get("status") in ("fail", "warn")]
        out.append("./revit doctor: %s" % ("%d problem%s" % (len(probs), "" if len(probs) == 1 else "s")
                                           if probs else "no problems found"))
        for x in probs[:60]:
            out.append("  %s %s: %s" % ("\u2717" if x.get("status") == "fail" else "!", x.get("id", "?"),
                                        str(x.get("title", ""))[:300]))
            if x.get("fix"):
                out.append("      fix: %s" % str(x["fix"])[:300])
    else:
        out.append("./revit doctor: not run")
    last = f.get("last")
    if isinstance(last, dict):
        when, failed = str(last.get("time", "?"))[:10], " ".join(map(str, last.get("failed") or [])) or "none"
        out.append("Last install (%s): %s; failed steps: %s" % (when, last.get("result", "?"), failed))
    elif "install" in f.get("failed", {}):
        out.append("Last install: failed steps: %s" % (" ".join(f["failed"]["install"]) or "none"))
    seen, ages = set(), []
    for it in kept:
        a = it.get("age")
        if a and a[1] and a[0] not in seen:
            seen.add(a[0])
            line = "  %s: %s" % (a[0], _age(now - a[1]))
            if a[0] == "debug session" and now - a[1] >= 7 * 86400:
                line += "; if the problem is new, run ./revit debug %s%s first" % (year or "<year>", sfx)
            ages.append(line)
    out.append("")
    out.append("Logs in report.zip, by age:" if ages else "No logs in report.zip.")
    out += ages
    if year and "debug" not in c.facts.get("kinds", []):
        out.append("  no debug session: to record one, run ./revit debug %s%s, make the problem happen, quit Revit"
                   % (year, sfx))
    out.append("")
    out.append(_summary(counts, ident))
    cuts = ["%s %s" % (it["what"], it["cut"]) for it in kept if it.get("cut")]
    if cuts:
        out.append("Cut: " + "; ".join(cuts))
    for x in left:
        out.append("Left out: %s \u2014 %s." % (x["what"], x["reason"]))
    if manifest_left:
        out.append("Left out: manifest.txt \u2014 it holds personal data that could not be removed.")
    if c.skipped:
        out.append("Not included: %d file%s of the log folders (manifest.txt in report.zip says which and why)."
                   % (len(c.skipped), "" if len(c.skipped) == 1 else "s"))
    out.append("")
    out.append("report.py removes what it recognizes: read this file and report.zip before you post them.")
    text = "\n".join(out) + "\n"
    if len(text.encode("utf-8")) > REPORT_MAX:
        text = text.encode("utf-8")[:REPORT_MAX - 40].decode("utf-8", "ignore").rsplit("\n", 1)[0] + "\n\u2026 (cut)\n"
    return text


def _manifest_text(c, kept, left, now):
    out = ["report.zip, made by tools/report.py on %s UTC" % time.strftime("%Y-%m-%d %H:%M", time.gmtime(now)), "",
           "Included:"]
    for it in kept:
        src = " (from %s)" % it["src"] if it.get("src") else ""
        out.append("  %s \u2014 %s%s%s" % (it["name"], it["what"], src, "; cut " + it["cut"] if it.get("cut") else ""))
    if left:
        out += ["", "Left out:"] + ["  %s \u2014 %s: %s" % (x["member"], x["what"], x["reason"]) for x in left]
    if c.skipped:
        out += ["", "Not included:"] + ["  %s \u2014 %s" % (p, why) for p, why in c.skipped]
    return "\n".join(out) + "\n"


def _write_zip(path, members):
    if os.path.exists(path):
        os.remove(path)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in members:
            zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type, zi.external_attr = zipfile.ZIP_DEFLATED, 0o644 << 16
            z.writestr(zi, data)
    return os.path.getsize(path)


def _bottle_dir(bottles, bottle):
    if not bottles or not bottle:
        return None
    b = os.path.join(bottles, bottle)
    return b if os.path.isdir(b) and not os.path.islink(b) else None


def build(root, data, bottles, out_dir, year=None, bottle=None, run=None, doctor_json=None, exclude=(),
          identity=None, now=None):
    """Make report.txt and report.zip in out_dir -> {report_txt, report_zip, left_out, summary, refused, hits}.
    refused (no report, nothing written) when report.txt fails the gate. identity: learned from this Mac and the
    bottle when not given (tests pass a synthetic one)."""
    now = time.time() if now is None else now
    year = str(year) if year else None
    bdir = _bottle_dir(bottles, bottle)
    if identity is None:
        identity = collect_identity(root, data, bdir, year, bottle)
    c = _collect(root, data, bdir, year, bottle, run, doctor_json, now)
    ex = set(exclude or ())
    kept, left, counts = [], [], collections.Counter()
    for it in c.items:
        if ex & {it["name"], os.path.basename(it["name"]), os.path.basename(it.get("src") or "")}:
            c.skipped.append((it.get("src") or it["name"], "left out on request (--exclude)"))
            continue
        text, n = redact(it["text"], identity, rel=it.get("rel"))
        body, cut = _caps(text, it["keep"])
        if cut:
            it["cut"] = ", ".join(x for x in (it.get("cut"), cut) if x)
        reason, hits = _refused(it["name"], body), []
        if not reason:
            hits = gate(body, identity, it["name"]) + gate(it["name"], identity, it["name"])
            if hits:
                reason = "it holds personal data that could not be removed"
        if reason:
            left.append({"member": it["name"], "what": it["what"], "reason": reason, "hits": hits})
            continue
        counts.update(n)
        it["body"] = body
        kept.append(it)
    tmp = tempfile.mkdtemp(prefix="revit-report-")   # 0700
    try:
        while True:
            mtext, _ = redact(_manifest_text(c, kept, left, now), identity)
            mbody, _ = _caps(mtext, "head")
            mhits = gate(mbody, identity, "manifest.txt")
            rtext, _ = redact(_report_text(c, root, year, bottle, kept, left, counts, identity, now, bool(mhits)),
                              identity)
            rbody = rtext.encode("utf-8")
            rhits = gate(rbody, identity, "report.txt")
            if rhits:
                return {"report_txt": None, "report_zip": None, "summary": None, "hits": rhits,
                        "left_out": [{k: x[k] for k in ("member", "what", "reason", "hits")} for x in left],
                        "refused": "report.txt holds personal data that could not be removed"}
            members = [(it["name"], it["body"]) for it in kept] + ([] if mhits else [("manifest.txt", mbody)])
            zpath = os.path.join(tmp, "report.zip")
            if _write_zip(zpath, members) > ZIP_MAX and kept:
                it = kept.pop()
                left.append({"member": it["name"], "what": it["what"], "reason": "the report would be over 5 MB",
                             "hits": []})
                continue
            bad = []   # the gate once more, over the members as read from the finished zip
            with zipfile.ZipFile(zpath) as z:
                for zi in z.infolist():
                    h = gate(zi.filename, identity, zi.filename) + gate(z.read(zi), identity, zi.filename)
                    if h or _refused(zi.filename, b""):
                        bad.append((zi.filename, h))
            if not bad:
                break
            for name, h in bad:
                for it in list(kept):
                    if it["name"] == name:
                        kept.remove(it)
                        left.append({"member": name, "what": it["what"], "hits": h,
                                     "reason": "it holds personal data that could not be removed"})
                if name == "manifest.txt":
                    return {"report_txt": None, "report_zip": None, "summary": None, "hits": h, "left_out": [],
                            "refused": "the finished report did not pass the check"}
        with open(os.path.join(tmp, "report.txt"), "wb") as f:
            f.write(rbody)
        os.makedirs(out_dir, exist_ok=True)
        rt, rz = os.path.join(out_dir, "report.txt"), os.path.join(out_dir, "report.zip")
        shutil.move(os.path.join(tmp, "report.txt"), rt)
        shutil.move(zpath, rz)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return {"report_txt": rt, "report_zip": rz, "summary": _summary(counts, identity), "refused": None, "hits": [],
            "left_out": [{k: x[k] for k in ("member", "what", "reason", "hits")} for x in left]}


# ---------------------------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------------------------
def _tilde(p):
    h = os.path.expanduser("~")
    return "~" + p[len(h):] if p and (p == h or p.startswith(h + "/")) else p


def _gate_file(path, ident, label):
    hits = []
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for zi in z.infolist():
                name = "%s:%s" % (label, zi.filename)
                hits += gate(zi.filename, ident, name) + gate(z.read(zi), ident, name)
        return hits
    with open(path, "rb") as f:
        done = 0
        while True:   # big files in blocks that end at a line end; line numbers go on across blocks
            block = f.read(8 << 20)
            if not block:
                break
            more = f.read(1)
            if more:
                rest = f.readline()
                block += more + rest
            for h in gate(block, ident, label):
                h["line"] += done
                hits.append(h)
            done += block.count(b"\n")
    return hits


def main(argv=None):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = argparse.ArgumentParser(prog="report.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd")
    for name in ("build", "gate"):
        s = sub.add_parser(name)
        s.add_argument("--root", default=here)
        s.add_argument("--data", default=None)
        s.add_argument("--bottles", default=os.path.expanduser("~/Library/Application Support/CrossOver/Bottles"))
        s.add_argument("--year")
        s.add_argument("--bottle")
        if name == "build":
            s.add_argument("--run")
            s.add_argument("--doctor-json")
            s.add_argument("--exclude", action="append", default=[])
            s.add_argument("--out-dir", required=True)
            s.add_argument("--json", action="store_true")
        else:
            s.add_argument("files", nargs="+")
    a = p.parse_args(argv)
    if not a.cmd:
        p.print_usage(sys.stderr)
        return 2
    data = a.data or os.environ.get("REVIT_DATA") or a.root
    if a.year and not re.fullmatch(r"\d{4}", a.year):
        print("report.py: --year takes a year such as 2027", file=sys.stderr)
        return 2
    if a.bottle and not re.fullmatch(r"[A-Za-z0-9_-]+(\.test)?", a.bottle):
        print("report.py: --bottle takes a bottle name", file=sys.stderr)
        return 2
    try:
        if a.cmd == "gate":
            ident = collect_identity(a.root, data, _bottle_dir(a.bottles, a.bottle), a.year, a.bottle)
            n = 0
            for f in a.files:
                for h in _gate_file(f, ident, os.path.basename(f)):
                    print(hit_line(h))
                    n += 1
            return 1 if n else 0
        r = build(a.root, data, a.bottles, a.out_dir, a.year, a.bottle, a.run, a.doctor_json, a.exclude)
    except KeyboardInterrupt:
        return 130
    except Exception as e:   # the message could hold a value: only its type and place
        tb = e.__traceback__
        while tb.tb_next:
            tb = tb.tb_next
        print("report.py: internal error (%s at line %d)" % (type(e).__name__, tb.tb_lineno), file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps({k: r[k] for k in ("report_txt", "report_zip", "left_out", "summary", "refused", "hits")}))
    elif r["refused"]:
        print("No report: %s." % r["refused"], file=sys.stderr)
        for h in r["hits"]:
            print("  " + hit_line(h), file=sys.stderr)
    else:
        print("Report: %s (paste it into the issue)" % _tilde(r["report_txt"]))
        print("Attach: %s" % _tilde(r["report_zip"]))
        print(r["summary"])
        for x in r["left_out"]:
            print("Left out: %s \u2014 %s." % (x["what"], x["reason"]))
            for h in x["hits"]:
                print("  " + hit_line(h))
    return 1 if r["refused"] else 0


if __name__ == "__main__":
    sys.exit(main())
