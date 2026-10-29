#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""A report for a GitHub issue with personal data removed: report.txt to paste, report.zip to attach.

  report.py build --root R --data D --bottles B [--year Y --bottle N] [--run DIR] [--doctor-json F]
                  [--exclude NAME]... --out-dir DIR [--json]
  report.py gate <file>... [--root R --data D --bottles B --year Y --bottle N]

build takes files by type and only the parts that help (never a whole log, nothing from sign-in, licensing or a
browser), puts placeholders such as <USER> where personal data was, then checks every part again with a gate that does
not trust the replacing. Of a log (a failed step's or action's, an MSI log, stdout.log, wine.cxlog) it takes only the
lines that report an error or a crash (its own list and the warn signatures of tools/signatures.py), each checked on
its own, and the fields of a CrossOver header; of a Revit journal, its allowed lines. A part that fails the gate is
left out and report.txt says so; when report.txt itself fails, there is no report (exit 1). The parts are made in a
private temporary folder; only what passed is moved to DIR.
--json prints {report_txt, report_zip, left_out[], summary, refused, hits}.

gate checks finished files (a zip member by member; JSON by its string values too): each hit as rule, file, line,
value class and length, never the value; exit 1 on any hit.

What it learns about this Mac and the bottle (user name, computer name, serial number, the Autodesk user name and ID)
stays in memory: it is never written or printed. It learns every bottle name the parts hold (a report without a year
reads the runs of all), and the Autodesk identity of each bottle. Nothing is sent anywhere. A library too:
learn_identity, learn_bottles, redact, gate, journal_extract, journal_file, error_extract, msi_extract, cxlog_extract,
build. Run with python3 -I -B.
"""
import argparse
import bisect
import collections
import ipaddress
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
import unicodedata
import urllib.parse
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bottleread  # noqa: E402
import signatures  # noqa: E402

REPORT_MAX = 20 * 1024          # report.txt: well inside a GitHub issue body (~65,000 characters)
ZIP_MAX = 5 * 1024 * 1024
MEMBER_MAX = 256 * 1024
LINE_MAX = 2000
ERROR_LINES = 100               # error lines kept of one log: the first and the last half when there are more
JOURNAL_MAX = 1000              # kept journal lines
JOURNAL_READ = 64 << 20         # a bigger journal is read by its start and its end
JRN_CONT = 40                   # kept lines of one journal statement with '_' continuations
READ_LINE = 4000                # a line read from a log is cut to this many characters
NUL_MAX = 0.01
SCAN_BLOCK, SCAN_MAX = 16 << 20, 4 << 30   # a big log is searched in blocks, up to its length when opened
CX_HEAD_LINES = 600             # the start of a cxlog read line by line: its header

# ---- placeholders: class -> (token, what the summary calls it). {} in a token is a number (same value, same number)
LABELS = {
    "user": ("<USER>", "your user name"), "name": ("<NAME>", "your name"), "home": ("~", "home folder path"),
    "data": ("<DATA>", "data folder path"), "repo": ("<REPO>", "project folder path"),
    "host": ("<HOST>", "Mac name"), "adsk_user": ("<ADSK-USER>", "Autodesk user name"),
    "adsk_id": ("<ADSK-ID>", "Autodesk ID"), "serial": ("<MAC-SERIAL>", "Mac serial number"),
    "hw_uuid": ("<HW-UUID>", "hardware UUID"), "mac": ("<MAC-ADDR>", "network address"),
    "ip": ("<IP-{}>", "IP address"), "email": ("<EMAIL>", "email address"), "bottle": ("<BOTTLE>", "bottle name"),
    "private": ("<PRIVATE>", "word from your list"), "volume": ("<VOLUME-{}>", "volume name"),
    "model": ("<MODEL-{}>", "model name"), "dir": ("<DIR-{}>", "folder name"),
    "secret": ("<SECRET>", "sign-in token"), "query": ("<VALUE>", "web address value"),
    "adsk_serial": ("<SERIAL>", "Autodesk serial number"), "tmpdir": ("<TMPDIR>", "temporary folder path"),
    "gdrive": ("<GDRIVE-PATH>", "path on G: (Google Drive)"),
}
ORDER = ("user", "name", "home", "data", "repo", "host", "adsk_user", "adsk_id", "serial", "hw_uuid", "mac", "ip",
         "email", "bottle", "private", "volume", "model", "dir", "secret", "query", "adsk_serial", "tmpdir", "gdrive")
NUMBERED = ("ip", "volume", "model", "dir")
PHASE = {"adsk_user": 1, "adsk_id": 1, "host": 2}   # Autodesk identity, then the host, then the other words (3)
TOKEN = re.compile(r"<(?:DATA|REPO|USER|NAME|HOST|ADSK-USER|ADSK-ID|MAC-SERIAL|HW-UUID|MAC-ADDR|EMAIL|BOTTLE|PRIVATE|"
                   r"TMPDIR|SECRET|JWT|CALLBACK|VALUE|SERIAL|(?:IP|VOLUME|MODEL|DIR)-\d+)>", re.I)

# While redacting, a replaced span is a run of private-use characters: later rules cannot match inside it
S_OPEN, S_CLOSE, S_HOME = "\ue000", "\ue001", "\ue002"
S_ANY = "\ue000-\ue1ff"
S_RX = re.compile(S_OPEN + "([\ue100-\ue109]+)" + S_CLOSE)
S_ONLY = re.compile("[" + S_ANY + r"\s]*")

SEP = r"(?:[\\/]|%2[Ff]|%5[Cc])+"                     # / \ \\ \/ (JSON) %2F %5C
END = r"(?!\w|[-.]\w)"                                # a path value ends here, not inside a longer name
DRIVE = r"(?:(?<![A-Za-z])[A-Za-z]:)?"                # Z: and the like, not the e: of file:
_NOSEP = r"(?!%2[Ff]|%5[Cc])"

# a path on G: (Google Drive, step gdrive): its folders are the company's projects and its people. The rest of the line
# up to " | < > or a control character goes (characters a Windows name cannot have; ' and spaces it can)
GDRIVE_RX = re.compile(r"(?<![A-Za-z0-9])([gG]:)(?:[\\/]|%2[Ff]|%5[Cc])+(?!<GDRIVE-PATH>)[^\"|<>\x00-\x1f]+")
TMPDIR_RX = re.compile(DRIVE + r"(?:" + SEP + r"private)?" + SEP + r"var" + SEP + r"folders" + SEP +
                       r"[^\\/\s%]{1,4}" + SEP + r"[^\\/\s%]{4,40}" + SEP + r"[TC](?!\w)", re.I)
JWT_RX = re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")
BEARER_RX = re.compile(r"(?i)(\bbearer\s+)([A-Za-z0-9._~+/=-]{8,})")
CALLBACK_RX = re.compile(r"(?i)(\badskidmgr:)([^\s\"'<>" + S_ANY + r"]+)")
KEYSECRET_RX = re.compile(r"(?i)\b(access_token|refresh_token|id_token|client_secret|code_verifier|password|passwd)"
                          r"([\"']?\s{0,2}[=:]\s{0,2}[\"']?)([^\s\"'&,;<>" + S_ANY + r"]{6,})")
URL_RX = re.compile(r"(?i)(\bhttps?:(?://|" + SEP + r")[^\s?#\"']+)([?#][^\s\"']*)")
QPAIR_RX = re.compile(r"([?#&;][^=&;?#]*)=([^&;#?]*)")
EMAIL_RX = re.compile(r"[\w.%+-]{1,64}@[\w-]+(?:\.[\w-]+)*\.[^\W\d_]{2,}")
# the documentation domains only, as the whole address: a noreply address still names its owner
EMAIL_OK = re.compile(r"(?i)[a-z0-9_.%+-]+@example\.(?:com|org|net)")   # fullmatch
MAC_RX = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
# IP addresses: only in a network context, so version and build numbers (27.3.0.28) stay
IP4_RX = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\w|\.\d)")
IP6_RX = re.compile(r"(?<![\w:.])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:(?:\.\d{1,3}){3})?(?![\w:]|\.\d)")
NET_WORDS = re.compile(r"(?i)(?<![^\W_])(?:ip|ipv[46]|address(?:es)?|addr|host(?:name)?s?|connect\w*|socket\w*|url|"
                       r"uri|https?|server|tcp|udp|dns|proxy)(?![^\W_])")
# right before: http://, a //host or \\host that starts a path (not the doubled \\ of a path in a Wine log), :\/\/ of
# JSON, user@; right after: :port
NET_BEFORE = re.compile(r"(?:(?:(?<![\w.\\/-])|:)//|:\\/\\/|(?<![\w.\\/$-])(?:\\\\)+|@)\[?$")
NET_PORT = re.compile(r"\]?:\d{1,5}(?!\d)")
# on a line with a network word, still a version: AddInVersion: 1.2.3.4, CrossOver/24.3.60.12, a folder ...\1.2.3.4
VERSION_BEFORE = re.compile(r"(?i)(?:(?:version|build|release|revision)|(?<![^\W_])(?:ver|v))[\s=:\"'(]*$|"
                            r"(?<![^\s(\"'])[a-z][\w.-]*/$|[\\/]$")
ADSK_SERIAL_RX = re.compile(r"(?i)(serial(?:[ _]?(?:number|no))?|csn|sn|adlm_serial\w*)(\W{1,4})(?!000-00000000)"
                            r"(\d{3}-\d{8})(?!\d)")
VOL_RX = re.compile(r"(?i)(" + SEP + r"Volumes" + SEP + r")((?:" + _NOSEP + r"[^\\/\r\n\"'<>|*?:\t" + S_ANY + r"])+)")
MODEL_EXT = r"rvt|rfa|rte|rft|rvg|ifc|dwg|nwc|nwd"
# A model's name: in a path, all of it back to the separator (' [ ] : = are part of a name there: O'Brien House (v2):
# final.rvt); elsewhere back to a quote, bracket or the like, an apostrophe between letters still part of it
_PSTEM = _NOSEP + r"[^\\/\"<>|\t*?\r\n" + S_ANY + r"]"
_STEM = _NOSEP + r"(?:[^\\/\[\]\"'=<>|\t:*?\r\n" + S_ANY + r"]|(?<=[^\W\d_])'(?=[^\W\d_]))"
MODEL_RX = re.compile(r"(?:(?P<sep>[\\/]|%2[Ff]|%5[Cc])(?P<pstem>(?:" + _PSTEM + r")*?)|(?P<lead>^|[\[\]\"'=<>|\t:*?" +
                      S_ANY + r"])(?P<stem>(?:" + _STEM + r")*?))(?P<ext>\.(?:" + MODEL_EXT + r"))(?![A-Za-z0-9])",
                      re.I | re.M)
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
# ~/Library is not the user's, except the cloud folders in it (OneDrive, Dropbox, Google Drive, iCloud Drive): there
# an account folder and all below it are; an app's own folder in iCloud Drive (com~apple~CloudDocs) is not
CLOUD_ROOTS = ("cloudstorage", "mobile documents")
CLOUD_CONTAINER = re.compile(r"(?i)(?:com|icloud)~[a-z0-9._~-]+")   # fullmatch
SEP_RX = re.compile(SEP)
SEG_STOP = frozenset("\r\n\"<>|*?\t")   # no path segment has these; ' [ ] : and spaces it can have
NEW_PATH_RX = re.compile(r"\s+['\"\[(]?(?:[A-Za-z]:|~)" + SEP)   # a space before another path ends a segment
# the extension of a path's last part: at its end, or (starting with a letter) before a : , ; ) ' ] or "
LAST_EXT = re.compile(r"\.(?:[A-Za-z0-9]{1,5}(?=\s*$)|[A-Za-z][A-Za-z0-9]{0,4}(?=[:,;)'\]\"]))")
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
# (the path only: its folders, then a last part up to its extension, or to the first space)
_XSEG = _NOSEP + r"[^\\/\r\n\"'<>|\t;,=:()\[\]" + S_ANY + r"]"
_XEND = _NOSEP + r"[^\\/\s\"'<>|;,=:()\[\]" + S_ANY + r"]"
EXEMPT_RX = re.compile(r"(?i)(?:program files(?: \(x86\))?" + SEP + r"autodesk" + SEP + r"|" + SEP + r"fonts" + SEP +
                       r")(?:(?:" + _XSEG + r")*" + _XEND + SEP + r")*(?:(?:" + _XSEG + r")*?\.[A-Za-z0-9]{1,5}"
                       r"(?![A-Za-z0-9])|(?:" + _XEND + r")*)")
# Wine's escapes in its own log lines: \x00fc (a wide string), \xc3\xbc (the UTF-8 bytes of a narrow one); not an
# escaped backslash and an x
WINE_LINE = re.compile(r"(?:^|[\s:])[0-9a-f]{4}:(?:[0-9a-f]{4}:)?(?:err|warn|fixme|trace|info|Call|Ret):")
XESC_RX = re.compile(r"(?<!\\)((?:\\\\)*)((?:\\x[89a-fA-F][0-9a-fA-F]){2,}|\\x[0-9a-fA-F]{4})")
# a backslash that is neither doubled nor one of Wine's escapes: a raw path (C:\users\...), where \x2026 is a folder
RAW_BACKSLASH = re.compile(r"(?<!\\)(?:\\\\)*\\(?![\\xnrt\"0])")

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
              ("cxlog", "a whole Wine log: only a debug session's error lines go into a report"))


# ---------------------------------------------------------------------------------------------------------------
# Identity: learned at run time, kept in memory
# ---------------------------------------------------------------------------------------------------------------
def _nfc(s):
    return unicodedata.normalize("NFC", s or "")


def _key(s):
    """The form values are compared in without case: NFC, casefolded (Stra\u00dfe and STRASSE are one), NFC again."""
    return unicodedata.normalize("NFC", _nfc(s).casefold())


def _ci(s):
    """A regex for s in any case (with re.I), also where case changes its length: Stra\u00dfe, STRASSE, strasse."""
    forms = {}
    for f in (_nfc(s), _nfc(s.upper()), _key(s)):
        forms.setdefault(f.lower(), f)   # re.I matches forms that only differ in simple case
    alts = sorted(forms.values(), key=lambda f: (-len(f), f))
    return re.escape(alts[0]) if len(alts) == 1 else "(?:" + "|".join(re.escape(f) for f in alts) + ")"


class Identity:
    """The personal values report.py removes. They live in this object only: repr() shows counts, never a value.
    Every value is kept in NFC, as the text it is looked for in."""

    def __init__(self):
        self.paths, self.words, self.homes = [], [], []
        self.login = None
        self.numbers = {k: {} for k in NUMBERED}   # value (caseless) -> number, in order of first appearance
        self.used = {k: set() for k in NUMBERED}
        self._rx = self._gate = None

    def __repr__(self):
        return "<Identity: %d paths, %d words>" % (len(self.paths), len(self.words))

    __str__ = __repr__

    def add_path(self, cls, p):
        p = os.path.normpath(_nfc(p)).rstrip("/") if p else ""
        if len(p) >= 4 and p.startswith("/") and (cls, p) not in self.paths:
            self.paths.append((cls, p))
            if cls == "home" and p not in self.homes:
                self.homes.append(p)
            self._rx = self._gate = None

    def add_word(self, cls, v):
        v = _nfc(v).strip()
        if not v or _key(v) == "crossover" or any(_key(w) == _key(v) for _, w in self.words):
            return
        self.words.append((cls, v))
        if cls in NUMBERED:
            self.numbers[cls].setdefault(_key(v), len(self.numbers[cls]) + 1)
        self._rx = self._gate = None

    def number(self, kind, name):
        n = self.numbers[kind].setdefault(_key(name.strip()), len(self.numbers[kind]) + 1)
        self.used[kind].add(n)
        return n

    def token(self, cls, value):
        t = LABELS[cls][0]
        return t.format(self.number(cls, value)) if cls in NUMBERED else t

    def gate_values(self):
        """[(normalized value, class, 'path'|'word'|'login')] for the gate: paths in every root form, words of 3+
        characters (whole words, as the redaction replaces them), a shorter login in its anchored fields only."""
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
        if self.login and len(self.login) < 3:
            out.append((_normalize(self.login), "user", "login"))
        return out

    def gate_rx(self):
        if self._gate is None:
            self._gate = []
            for v, cls, kind in self.gate_values():
                if kind == "path":
                    rx = re.escape(v) + END
                elif kind == "word":
                    rx = r"(?<![^\W_])" + re.escape(v) + r"(?![^\W_])"
                else:   # USER=jo, LOGNAME: jo (a path with it is the users-path rule's)
                    rx = r"\b(?:user|logname)[ \t]*[=:][ \t]*\"?" + re.escape(v) + r"(?=[\s\",;]|\Z)"
                self._gate.append((v, cls, kind, re.compile(rx)))
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
                    phases.setdefault(PHASE.get(cls, 3), {}).setdefault(_key(v), (cls, v))
            words = {p: (_word_rx([v for _, v in d.values()]), {k: c for k, (c, _) in d.items()})
                     for p, d in phases.items()}
            login = None
            if self.login:
                login = re.compile(r"(?i)(" + SEP + r"Users" + SEP + r")(" + _ci(self.login) + r")" + END)
            self._rx = (paths, words, login)
        return self._rx


def _path_forms(p, homes):
    """Regexes for a POSIX path in every form a log gives it: Z:\\..., \\\\, \\/, %2F, file://, any case; under the home
    also as ~/... and CrossOver's Y:\\..."""
    body = "".join(SEP + _ci(x) for x in p.split("/") if x)
    forms = [DRIVE + body + END]
    for h in homes:
        if p != h and p.startswith(h + "/"):
            tail = "".join(SEP + _ci(x) for x in p[len(h):].split("/") if x)
            forms += [r"(?<![\w~])~" + tail + END, r"(?<![^\W_])[Yy]:" + tail + END]
    return forms


def _word_rx(values):
    alts = "|".join(_ci(v) for v in sorted(values, key=lambda v: (-len(v), v)))
    return re.compile(r"(?<![^\W_])(?:" + alts + r")(?![^\W_])", re.I)


STOCK_HOSTS = ("mac", "macbook", "macbook-air", "macbook-pro", "imac", "mac-mini", "mac-studio", "mac-pro",
               "localhost")
DEFAULT_BOTTLE_RX = re.compile(r"^rvt\d{4}-[a-z0-9]{1,4}$", re.I)


def _as_list(v):
    if v is None:
        return []
    return [_nfc(v)] if isinstance(v, str) else [_nfc(x) for x in v if x]


def _parts(v, min_len=3):
    return [p for p in re.split(r"[\s,.;:()+_@-]+", v or "") if len(p) >= min_len and not p.isdigit()]


def learn_identity(facts):
    """facts (dict, every key optional) -> Identity. Keys: login, gecos, home, data, root (a path or a list of
    paths), hosts (ComputerName, LocalHostName, HostName, hostname...), volumes, adsk_user, adsk_id, journal_user,
    serial, hw_uuid, macs, git_name, git_email, bottle, denylist. Values in any Unicode form: they are kept in NFC."""
    ident = Identity()
    for cls, key in (("data", "data"), ("repo", "root"), ("home", "home")):
        for p in _as_list(facts.get(key)):
            ident.add_path(cls, p)
    login = _nfc(facts.get("login")).strip()
    if login:
        ident.login = login
        ident.add_word("user", login)
    gecos = _nfc(facts.get("gecos")).strip()
    if gecos and _key(gecos) != _key(login):
        ident.add_word("name", gecos)
        for p in _parts(gecos):
            ident.add_word("name", p)
    for h in _as_list(facts.get("hosts")):
        h = re.sub(r"(?i)\.local\.?$", "", h.strip())
        short = h.split(".")[0]
        for v in (h, short, short.upper()[:15]):   # Wine's ComputerName: upper case, the first 15 characters
            if v and _key(v) not in STOCK_HOSTS:
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
    b = _nfc(facts.get("bottle")).strip()
    if b and not DEFAULT_BOTTLE_RX.match(b):
        ident.add_word("bottle", b)
    for v in _as_list(facts.get("denylist")):
        ident.add_word("private", v)
    return ident


def _run(cmd, env=None):
    exe = cmd[0]
    if not os.path.isabs(exe):
        exe = shutil.which(exe) or exe
    try:
        return subprocess.run([exe] + list(cmd[1:]), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=15, universal_newlines=True, env=env).stdout
    except (OSError, subprocess.SubprocessError, ValueError):
        return ""


def _git(root, *args):
    """git in the clone, read only: no optional locks, so git status never refreshes and writes the index."""
    return _run(["git", "--no-optional-locks", "-C", root] + list(args),
                env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))


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
        f["git_name"] = _git(root, "config", "user.name").strip()
        f["git_email"] = _git(root, "config", "user.email").strip()
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


BOTTLE_NAME = re.compile(r"[^/\x00-\x1f]{1,255}")   # fullmatch: CrossOver takes any bottle name but '/'
NOT_BOTTLES = re.compile(r"(?i)mac|runs|default|revit\d{4}")   # fullmatch: the other folders of logs/
BOTTLES_MAX = 64


def _bottle_name(n, real=False):
    """A bottle name (of a test copy: its source's), or None. real: a folder in the Bottles folder, learned as it is.
    Otherwise (a folder of logs/, a field of a run record or test result, a doctor check id): any name CrossOver takes,
    of any length, that is not another folder of logs/. Learning a word too many costs only readability."""
    n = (n or "").strip()
    n = n[:-len(".test")] if n.endswith(".test") else n
    if real:
        return n[:255] or None
    return n if BOTTLE_NAME.fullmatch(n) and not NOT_BOTTLES.fullmatch(n) else None


def _bottle_years(bottle_dir):
    """The Revit years of a bottle, by the names of its folders only (no file is opened): Program Files\\Autodesk\\
    Revit <year>, the user's Revit folders and ProgramData\\Autodesk\\RVT <year>."""
    ys, dc = set(), os.path.join(bottle_dir, "drive_c")
    adsk = os.path.join(dc, "users", "crossover", "AppData", "%s", "Autodesk", "Revit")
    for d, rx in ((os.path.join(dc, "Program Files", "Autodesk"), r"Revit (\d{4})"),
                  (adsk % "Roaming", r"Autodesk Revit (\d{4})"), (adsk % "Local", r"Autodesk Revit (\d{4})"),
                  (os.path.join(dc, "ProgramData", "Autodesk"), r"RVT (\d{4})")):
        for n in _listdir(d):
            m = re.fullmatch(rx, n)
            if m:
                ys.add(m.group(1))
    return sorted(ys)[-8:]


def learn_bottles(ident, data, bottles, names=()):
    """Every bottle a report can name, added to ident: the bottles in the Bottles folder, the folders of DATA/logs and
    names (from doctor's checks, run records, test results). A name that is not rvt<year>-<x> is learned, and the
    Autodesk user name and ID of each bottle in the Bottles folder (its Revit.ini and newest journal of each Revit
    year). For a report without a year, which reads the runs and the checks of every bottle."""
    found, dirs = list(names), []
    if data:   # folders only: logs/ also holds files (the trackpad helper's log), not bottles
        logs = os.path.join(data, "logs")
        found += [n for n in _listdir(logs)
                  if os.path.isdir(os.path.join(logs, n)) and not os.path.islink(os.path.join(logs, n))]
    for n in (_listdir(bottles) if bottles else [])[:4 * BOTTLES_MAX]:
        p = os.path.join(bottles, n)
        if os.path.isdir(p) and not os.path.islink(p) and not NEVER_OPEN_RX.search(p):
            dirs.append(p)
            b = _bottle_name(n, real=True)
            if b and not DEFAULT_BOTTLE_RX.match(b):
                ident.add_word("bottle", b)
    for n in found:
        b = _bottle_name(n)
        if b and not DEFAULT_BOTTLE_RX.match(b):
            ident.add_word("bottle", b)
    for p in dirs[:BOTTLES_MAX]:
        for y in _bottle_years(p):
            f = bottle_facts(p, y)
            for key, cls in (("adsk_user", "adsk_user"), ("journal_user", "adsk_user"), ("adsk_id", "adsk_id")):
                for v in _as_list(f.get(key)):
                    ident.add_word(cls, v)
    return ident


def collect_identity(root, data, bottle_dir=None, year=None, bottle=None, bottles=None):
    """learn_identity over this Mac, the bottle and the denylists; with bottles (the Bottles folder), learn_bottles."""
    facts = machine_facts(root, data)
    facts.update(bottle_facts(bottle_dir, year))
    facts["bottle"] = bottle
    ident = learn_identity(facts)
    return learn_bottles(ident, data, bottles) if bottles else ident


# ---------------------------------------------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------------------------------------------
class _Text:
    def __init__(self, text):
        self.tokens, self.counts = [], collections.Counter()
        text = re.sub("[" + S_ANY + "]", "\ufffd", _nfc(text))   # NFC, as the learned values and the gate
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
    path = m.group("sep") is not None
    stem = m.group("pstem") if path else m.group("stem")
    if not stem or stem[-1].isspace():
        return m.group(0)   # ".rvt files", "*.rvt": no name there
    core = stem.strip()
    if not core or core.lower() in AUTODESK_STEMS or AUTODESK_STEM_RX.match(core):
        return m.group(0)
    lead = stem[:len(stem) - len(stem.lstrip())]
    return (m.group("sep") if path else m.group("lead")) + lead + \
        t.tok("<MODEL-%d>" % ident.number("model", core), "model") + m.group("ext")


def _is_sep(text, j):
    return j < len(text) and text[j] in "\\/%" and SEP_RX.match(text, j) is not None


def _goes_on(text, j, is_sep, new_path):
    """Whether a path goes on after j: a separator before the end of the line, a character no path has, or another
    path (at most 400 characters on)."""
    for k in range(j, min(len(text), j + 400)):
        ch = text[k]
        if ch in SEG_STOP or "\ue000" <= ch <= "\ue1ff" or (ch.isspace() and new_path.match(text, k)):
            return False
        if is_sep(text, k):
            return True
    return False


def _seg_end(text, i, opener, is_sep=_is_sep, new_path=NEW_PATH_RX):
    """Where a path segment that starts at i ends: at a separator, at a character no path has, at a space before
    another path, or where a quote or bracket opened right before the path closes (a ' or ] that a word does not
    follow and after which the path does not go on). ' [ ] : and spaces are part of a name."""
    closer = {"'": "'", "[": "]"}.get(opener)
    depth, j, n = 0, i, len(text)
    while j < n:
        ch = text[j]
        if ch in SEG_STOP or "\ue000" <= ch <= "\ue1ff" or is_sep(text, j) or \
                (ch.isspace() and new_path.match(text, j)):
            break
        if ch == "[":
            depth += 1
        elif ch == "]" and depth:
            depth -= 1
        elif ch == closer and not (j + 1 < n and (text[j + 1].isalnum() or text[j + 1] == "_")) and \
                not _goes_on(text, j + 1, is_sep, new_path):
            break
        j += 1
    return j


def _last_split(name):
    """The last part of a path -> (its name, what follows that is not the name: an extension and any words after
    it, a closing quote, bracket or full stop)."""
    rest = ""
    k = re.search(r"[,;=]", name)
    if k:
        name, rest = name[:k.start()], name[k.start():]
    stripped = name.rstrip()
    name, rest = stripped, name[len(stripped):] + rest
    exts = [e for e in LAST_EXT.finditer(name) if e.start() > 0]
    if exts:
        return name[:exts[-1].start()], name[exts[-1].start():] + rest
    while name and (name[-1] in "'\".,:;" or (name[-1] == ")" and name.count("(") < name.count(")")) or
                    (name[-1] == "]" and name.count("[") < name.count("]"))):
        name, rest = name[:-1], name[-1] + rest
    return name, rest


def _user_seg(step, mode, low, last, wine):
    """A path segment under a user root, the step-th: 'keep' (a standard folder on the way), 'stop' (what follows is
    not the user's) or 'dir' (the user's folder or file name) -> (what, mode). low: the segment stripped, lower case."""
    if step == 0:
        if low in USER_FOLDERS and not last:
            return "keep", None
        if low == "library" and not wine and not last:
            return "keep", "library"
        return ("stop" if wine or low in HOME_STANDARD or low in USER_FOLDERS else "dir"), None
    if mode == "library":
        return ("keep", low) if step == 1 and low in CLOUD_ROOTS and not last else ("stop", None)
    if mode == "mobile documents" and step == 2 and CLOUD_CONTAINER.fullmatch(low):
        return "keep", mode
    return "dir", mode


def _dirs(t, ident):
    """Each folder under a user root -> <DIR-n>; the last part of a path keeps a short extension."""
    text, out, pos = t.text, [], 0
    for m in DIR_ROOT_RX.finditer(text):
        if m.start() < pos:
            continue
        wine, opener = m.group("wine") is not None, text[m.start() - 1:m.start()]
        out.append(text[pos:m.end()])
        i, step, mode = m.end(), 0, None
        while True:
            s = SEP_RX.match(text, i)
            e = _seg_end(text, s.end(), opener) if s else 0
            if not s or e == s.end():
                break
            seg, last = text[s.end():e], not _is_sep(text, e)
            what, mode = _user_seg(step, mode, seg.strip().lower(), last, wine)
            step += 1
            if what == "stop":
                break
            if what == "keep":
                out.append(text[i:e])
                i = e
                continue
            name, rest = _last_split(seg) if last else (seg, "")
            if not name.strip():
                break
            out.append(text[i:s.end()] + t.tok("<DIR-%d>" % ident.number("dir", name), "dir") + rest)
            i = e
            if last:
                break
        pos = i
    out.append(text[pos:])
    t.text = "".join(out)


def _xesc(m):
    s = m.group(2)
    if s.count("\\x") == 1:   # \xXXXX: one character of a wide string
        n = int(s[2:], 16)
        return m.group(0) if n < 0x80 or 0xD800 <= n < 0xE000 else m.group(1) + chr(n)
    try:   # \xHH\xHH...: the UTF-8 bytes of a narrow string
        return m.group(1) + bytes.fromhex(s.replace("\\x", "")).decode("utf-8")
    except ValueError:
        return m.group(0)


def _wine_unescape(text, every_line=False):
    """Wine's \\x escapes of non-ASCII characters decoded, in its own log lines that hold no raw path (every_line: in
    all), so a learned value is found whole. Linear in the text; a decoded character is never a line end."""
    if "\\x" not in text:
        return text
    return "\n".join(XESC_RX.sub(_xesc, ln) if every_line or (WINE_LINE.search(ln) and not RAW_BACKSLASH.search(ln))
                     else ln for ln in text.split("\n"))


def _words(t, ident, rx, classes):
    spans = [(m.start(), m.end()) for m in EXEMPT_RX.finditer(t.text)]
    starts = [s for s, _ in spans]

    def fn(m):
        v = m.group(0)
        if v.isalpha():
            i = bisect.bisect_right(starts, m.start()) - 1
            if i >= 0 and m.start() < spans[i][1]:
                return v
        cls = classes.get(_key(v)) or next(iter(classes.values()))
        return t.tok(ident.token(cls, v), cls)
    t.sub(rx, fn)


def _ip_ok(v):
    """A real address that is not loopback or unspecified; an IPv4 without leading zeros (01.02 is a date or a
    version), an IPv6 with :: or all eight groups."""
    try:
        a = ipaddress.ip_address(v)
    except ValueError:
        return False
    if a.version == 4 and any(len(o) > 1 and o[0] == "0" for o in v.split(".")):
        return False
    if a.version == 6 and "::" not in v and v.count(":") != (6 if "." in v else 7):
        return False
    return not (a.is_loopback or a.is_unspecified or v == "255.255.255.255")


def _ip_spans(text):
    """(start, end) of each IP address in a network context: right after // or @, right before :port, or on a line
    that names the network (ip, address, host, connect, socket, url, http, server...) and not right after a version
    word. Loopback stays, and so does a version or build number (26.3.0.39832, 27.3.0.28) outside such a context."""
    out = []
    for rx in (IP4_RX, IP6_RX):
        for m in rx.finditer(text):
            s, e = m.span()
            if not _ip_ok(m.group(0)):
                continue
            if NET_BEFORE.search(text[max(0, s - 12):s]) or NET_PORT.match(text, e):
                out.append((s, e))
                continue
            ls = text.rfind("\n", 0, s) + 1
            le = text.find("\n", e)
            if NET_WORDS.search(text, ls, len(text) if le < 0 else le) and \
                    not VERSION_BEFORE.search(text[max(ls, s - 60):s]):
                out.append((s, e))
    return sorted(out)


def _ips(t, ident):
    text, out, pos = t.text, [], 0
    for s, e in _ip_spans(text):
        if s >= pos:
            out += [text[pos:s], t.tok(ident.token("ip", text[s:e]), "ip")]
            pos = e
    t.text = "".join(out) + text[pos:]


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
    t, ident = _Text(_wine_unescape(text)), identity
    paths, words, login_rx = ident._compiled()
    if rel:
        for rx in _rel_forms(rel, ident):
            t.sub(rx, lambda m: "")
    for cls, rx in paths:   # DATA and REPO before the home (longer first), in POSIX, Z:, ~ and Y: forms
        t.sub(rx, lambda m, c=cls: t.tok(LABELS[c][0], c))
    t.sub(TMPDIR_RX, lambda m: t.tok("<TMPDIR>", "tmpdir"))
    t.sub(GDRIVE_RX, lambda m: m.group(1) + "\\" + t.tok("<GDRIVE-PATH>", "gdrive"))
    t.sub(JWT_RX, lambda m: t.tok("<JWT>", "secret"))
    t.sub(BEARER_RX, lambda m: m.group(1) + t.tok("<SECRET>", "secret"))
    t.sub(CALLBACK_RX, lambda m: m.group(1) + t.tok("<CALLBACK>", "secret"))
    t.sub(KEYSECRET_RX, lambda m: m.group(1) + m.group(2) + t.tok("<SECRET>", "secret"))
    t.sub(URL_RX, lambda m: m.group(1) + QPAIR_RX.sub(
        lambda q: q.group(1) + "=" + (t.tok("<VALUE>", "query") if _real(q.group(2)) else q.group(2)), m.group(2)))
    t.sub(EMAIL_RX, lambda m: m.group(0) if EMAIL_OK.fullmatch(m.group(0)) else t.tok("<EMAIL>", "email"))
    t.sub(MAC_RX, lambda m: t.tok("<MAC-ADDR>", "mac"))
    _ips(t, ident)
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
        if key in ("logonuser", "username") and _key(v) not in BENIGN_USERS and _real(v):
            return m.group(1) + m.group(2) + t.tok("<USER>", "user")
        first = v.split()[0]
        rest = USER_KEY_RX.sub(user_key, v[len(first):])   # USER=jo LOGNAME=jo: the next key too
        if ident.login and _key(first) == _key(ident.login):
            return m.group(1) + m.group(2) + t.tok("<USER>", "user") + rest
        return m.group(1) + m.group(2) + first + rest
    t.sub(USER_KEY_RX, user_key)
    t.sub(OWNER_RX, lambda m: m.group(1) + m.group(2) + t.tok("<NAME>", "name"))
    if 3 in words:
        _words(t, ident, *words[3])
    return t.done(), dict(t.counts)


# ---------------------------------------------------------------------------------------------------------------
# The gate: independent of the redaction, fails closed
# ---------------------------------------------------------------------------------------------------------------
PCT_RX = re.compile(r"%[0-9A-Fa-f]{2}")
PCT_EOL = re.compile(r"%0[AaDd]")
JSON_U = re.compile(r"\\u([0-9A-Fa-f]{4})(?:\\u([0-9A-Fa-f]{4}))?")


def _light(s):
    """What the gate reads before it folds separators: percent escapes decoded in full (%2F, %C3%A9, %252F: at most
    three rounds; a decoded line break becomes a space, so lines keep their numbers), then NFC and casefolded."""
    for _ in range(3):
        if not PCT_RX.search(s):
            break
        d = urllib.parse.unquote(PCT_EOL.sub(" ", s), errors="replace")
        if d == s:
            break
        s = d
    return _key(s)


def _fold(s):
    """\\, \\\\, \\/ (JSON), file://, \\??\\ and \\\\?\\ all become one /."""
    s = s.replace("file://", "/")
    s = re.sub(r"\\+", "/", s)
    s = re.sub(r"/+\?\?/|/+\?/", "/", s)
    return re.sub(r"/{2,}", "/", s)


def _normalize(s):
    return _fold(_light(s))


def _json_char(n):
    return " " if n < 0x20 else "\ufffd" if 0xD800 <= n < 0xE000 else chr(n)   # a control character: a space


def _json_u(m):
    a, b = int(m.group(1), 16), int(m.group(2), 16) if m.group(2) else None
    if b is not None and 0xD800 <= a < 0xDC00 and 0xDC00 <= b < 0xE000:   # a surrogate pair: one character
        return chr(0x10000 + ((a - 0xD800) << 10) + (b - 0xDC00))
    return _json_char(a) + ("" if b is None else _json_char(b))


def _unescape_json(s):
    """\\uXXXX (and a surrogate pair) as the character it stands for, in place: a JSON string that hides a value."""
    return JSON_U.sub(_json_u, s)


def _json_walk(x, out):
    if isinstance(x, str):
        out.append(x)
    elif isinstance(x, dict):
        for k, v in x.items():
            out.append(k)
            _json_walk(v, out)
    elif isinstance(x, list):
        for v in x:
            _json_walk(v, out)


def _json_strings(text):
    """[(line, string)] of every string (keys too) in the JSON of a text: the whole text when it is one JSON document,
    else each line that is a JSON object (NDJSON); [] when there is none."""
    out, s = [], text.strip()
    if s[:1] in "{[" and s[-1:] in "}]":
        try:
            doc = json.loads(s)
        except (ValueError, RecursionError):
            doc = None
        if doc is not None:
            found, pos, line = [], 0, 1
            _json_walk(doc, found)
            for v in found:   # the line of a string: where its JSON form is, after the one before it
                for form in (json.dumps(v, ensure_ascii=False)[1:-1], json.dumps(v)[1:-1]):
                    i = text.find(form, pos) if form else -1
                    if i >= 0:
                        line += text.count("\n", pos, i)
                        pos = i
                        break
                out.append((line, v))
            return out
    for n, ln in enumerate(text.split("\n"), 1):
        ln = ln.strip()
        if ln[:1] == "{" and ln[-1:] == "}" and len(ln) <= 1 << 20:
            try:
                found = []
                _json_walk(json.loads(ln), found)
            except (ValueError, RecursionError):
                continue
            out += [(n, v) for v in found]
    return out


# A /Users/ or /Volumes/ exemption holds only as a whole path segment: /Users/Shared/ and /Users/<USER> are not hits,
# a folder in Users named PublicAlice, shared-x or "Public Alice" is. A segment ends at /, at a character no path
# segment here has, at a full stop before a space, or at a space when what follows is not a path going on (no / before
# the next space).
_SEG_END = r"[\"'<>|*?\t\r\n\[\]:,;)]"
SEG_DONE = (r"(?:/|(?=" + _SEG_END + r"|\Z)|(?=\.(?:\s|" + _SEG_END + r"|\Z))|(?=[ ]+[^\s/\"'<>|*?\[\]:,;)]*(?:\s|" +
            _SEG_END + r"|\Z)))")
GATE_RULES = (   # (rule, value class, a regex over the folded text or a function over the unfolded one)
    ("users-path", "path", re.compile(r"/users/(?!(?:<[^/<>\s]+>|shared|public|crossover)" + SEG_DONE +
                                      r")[^/\s\"'|]+")),
    ("volumes-path", "path", re.compile(r"/volumes/(?!<volume-\d+>" + SEG_DONE + r")[^/\s\"'|]+")),
    ("jwt", "token", re.compile(r"eyj[a-z0-9_-]{8,}\.eyj[a-z0-9_-]{8,}\.[a-z0-9_-]{4,}")),
    ("bearer", "token", re.compile(r"\bbearer\s+(?!<)[a-z0-9._~+/=-]{8,}")),
    ("callback", "token", re.compile(r"adskidmgr:[^\s]*code=")),
    ("secret", "token", re.compile(r"\b(?:access_token|refresh_token|id_token|client_secret|code_verifier|password|"
                                   r"passwd)[\"']?\s{0,2}[=:]\s{0,2}[\"']?(?!<)[^\s\"'&,;<>]{6,}")),
    # a path on G: not replaced, or text of a path left after the placeholder
    ("gdrive-path", "path", re.compile(r"(?<![a-z0-9])g:/+(?:(?!<gdrive-path>)[^\s\"|<>]|<gdrive-path>[^\s\"|<>])")),
    ("mac-address", "address", re.compile(r"(?<![0-9a-f:-])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f:-])")),
    ("ip-address", "address", _ip_spans),   # the same network contexts as the redaction, on the unfolded text
    ("serial", "serial", re.compile(r"(?:serial|csn)\W{1,4}(?!000-00000000)\d{3}-\d{8}")),
    # the anchored fields of the redaction: their value is personal whatever it is
    ("journal-username", "adsk_user", re.compile(r'"username"[\s_]*,[\s_]*"(?!<adsk-user>"|")')),
    ("ini-user", "adsk_user", re.compile(r"(?m)^[ \t]*user(?:name|id)[ \t]*=[ \t]*(?!<|crossover\b)[^\s]")),
    ("attr-username", "adsk_user", re.compile(r"rvt\.attr\.username:[ \t]*(?!<|rvt\.)[^\s]")),
    ("consent-id", "adsk_id", re.compile(r"userconsent/(?!<)[a-z0-9]{6,}\.json")),
    ("host-key", "host", re.compile(r"\b(?:computername|hostname)[ \t]*[=:][ \t]*\"?(?!<)[^\s\",;]")),
    ("host-found", "host", re.compile(r"found for host[ \t]+(?!<)[^\s:]")),
    ("user-key", "user", re.compile(r"\b(?:logonuser|username)[ \t]*[=:][ \t]*\"?(?!<|(?:" + "|".join(BENIGN_USERS) +
                                    r")(?![^\s\",;]))[^\s\",;]")),
    ("owner", "name", re.compile(r"\b(?:regowner|regcompany|companyname|registeredowner|registeredorganization)"
                                 r"[ \t]*[=:][ \t]*\"?(?!<)[^\s\"]")),
)
# Stricter than the redaction: any local part; the documentation domains are exempt only for the plain address
GATE_EMAIL = re.compile(r"[^\s@<>()\[\],;:\"'/\\]{1,64}@[\w-]+(?:\.[\w-]+)*\.[^\W\d_]{2,}")
GATE_EMAIL_OK = re.compile(r"[a-z0-9_.%+-]+@example\.(?:com|org|net)")   # fullmatch
GATE_URL = re.compile(r"\bhttps?:/+[^\s?#\"']+([?#][^\s\"']*)")
GATE_MODEL = re.compile(r"\.(?:" + MODEL_EXT + r")(?![a-z0-9])")
GATE_STEM = re.compile(r"(?:[^/\[\]\"'=<>|\t:*?\r\n]|(?<=[^\W\d_])'(?=[^\W\d_]))*$")   # as _STEM
GATE_PSTEM = re.compile(r"/([^/\"<>|\t*?\r\n]*)$")                                     # as _PSTEM, after a /
GATE_DIR_ROOT = re.compile(r"(?:(?P<wine>(?<![^\W_])[a-z]:/users/crossover)|(?<![^\W_])y:|(?<![\w~])~)(?=/)")
GATE_NEW_PATH = re.compile(r"\s+['\"\[(]?(?:[a-z]:|~)/")
GATE_GLUED = re.compile(r"[\['(-]?[^\W_]")   # a name glued to a placeholder: <DIR-1>'Brien, <DIR-1>x
GATE_EXEMPT = re.compile(r"(?:program files(?: \(x86\))?/autodesk/|/fonts/)(?:[^/\r\n\"'<>|\t;,=:()\[\]]*"
                         r"[^/\s\"'<>|;,=:()\[\]]/)*(?:[^/\r\n\"'<>|\t;,=:()\[\]]*?\.[a-z0-9]{1,5}(?![a-z0-9])|"
                         r"[^/\s\"'<>|;,=:()\[\]]*)")


def _gate_sep(text, j):
    return j < len(text) and text[j] == "/"


def _email_ok(a):
    """The address the redaction keeps: its plain part (what follows the last character a plain address cannot
    have) at example.com, .org or .net."""
    local, dom = a.rsplit("@", 1)
    plain = re.search(r"[a-z0-9_.%+-]*$", local).group(0)
    return bool(plain) and bool(GATE_EMAIL_OK.fullmatch(plain + "@" + dom))


def _gate_text(norm, light, ident, name):
    """Hits in one text: norm is folded (_normalize), light only decoded (_light), for rules that need // and \\\\."""
    nl = [m.start() for m in re.finditer("\n", norm)]
    lnl = None
    hits = []

    def hit(rule, cls, pos, length):
        hits.append({"rule": rule, "file": name, "line": bisect.bisect_left(nl, pos) + 1, "class": cls,
                     "length": length})
    for rule, cls, rx in GATE_RULES:
        if callable(rx):
            for s, e in rx(light):
                lnl = lnl if lnl is not None else [m.start() for m in re.finditer("\n", light)]
                hits.append({"rule": rule, "file": name, "line": bisect.bisect_left(lnl, s) + 1, "class": cls,
                             "length": e - s})
            continue
        for m in rx.finditer(norm):
            hit(rule, cls, m.start(), len(m.group(0)))
    for m in GATE_EMAIL.finditer(norm):
        if not _email_ok(m.group(0)):
            hit("email", "email", m.start(), len(m.group(0)))
    for m in GATE_URL.finditer(norm):
        for q in QPAIR_RX.finditer(m.group(1)):
            v = q.group(2)
            if v and not TOKEN.fullmatch(v):
                hit("url-query", "token", m.start(), len(v))
    for m in GATE_MODEL.finditer(norm):
        before = norm[max(0, m.start() - 400):m.start()]
        tm = re.search(r"<model-\d+>$", before)
        if tm:   # a placeholder, and in a path nothing of a name before it (Henderson'<MODEL-1>.rvt is a hit)
            pm = GATE_PSTEM.search(before, 0, tm.start())
            if pm and re.search(r"[^\W_]", pm.group(1)):
                hit("model-file", "model", m.start(), len(pm.group(1)))
            continue
        pm = GATE_PSTEM.search(before)
        stem = pm.group(1) if pm else GATE_STEM.search(before).group(0)
        if not stem or stem[-1].isspace():
            continue
        core = stem.strip()
        if core and core not in AUTODESK_STEMS and not AUTODESK_STEM_RX.match(core):
            hit("model-file", "model", m.start(), len(core))
    for m in GATE_DIR_ROOT.finditer(norm):
        wine, opener = m.group("wine") is not None, norm[m.start() - 1:m.start()]
        i, step, mode = m.end(), 0, None
        while norm.startswith("/", i):
            tk = TOKEN.match(norm, i + 1)
            if tk:   # what follows a placeholder up to the next / is checked too: <DIR-1>'Brien Architects/...
                step += 1
                j = _seg_end(norm, tk.end(), opener, _gate_sep, GATE_NEW_PATH)
                piece = norm[tk.end():j]
                if piece and (norm.startswith("/", j) or GATE_GLUED.match(piece)):
                    hit("user-dir", "path", tk.end(), len(piece))
                    break
                i = j
                continue
            e = _seg_end(norm, i + 1, opener, _gate_sep, GATE_NEW_PATH)
            if e == i + 1:
                break
            seg, last = norm[i + 1:e], not norm.startswith("/", e)
            what, mode = _user_seg(step, mode, seg.strip(), last, wine)
            step += 1
            if what == "stop":
                break
            if what == "keep":
                i = e
                continue
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
    Each view is read as it is, with its \\uXXXX escapes decoded, with Wine's \\x00fc escapes decoded, and by the
    string values of its JSON; percent escapes are decoded, Unicode is compared in NFC without case. A hit never holds
    the value or any part of it."""
    views = [data] if isinstance(data, str) else [data.decode("utf-8", "replace")]
    if isinstance(data, bytes) and len(data) >= 2:
        views += [data.decode("utf-16-le", "ignore"), data[1:].decode("utf-16-le", "ignore")]
    seen, out = set(), []
    for v in views:
        texts = [(v, None)]
        if JSON_U.search(v):
            texts.append((_unescape_json(v), None))
        if XESC_RX.search(v):   # Wine's \x00fc, in any line: a view more can only find more
            texts.append((_wine_unescape(v, every_line=True), None))
        strings = _json_strings(v)
        if strings:   # one string a line; lines[i] is the line of the text it came from
            texts.append(("\n".join(re.sub(r"[\r\n]", " ", s) for _, s in strings), [n for n, _ in strings]))
        for t, lines in texts:
            light = _light(t)
            for h in _gate_text(_fold(light), light, identity, name):
                if lines:
                    h["line"] = lines[min(h["line"], len(lines)) - 1]
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


class Skipped:
    """In a stream of lines: n bytes in between were not read."""

    def __init__(self, n):
        self.n = n


def _budget(lines, limit):
    """lines until they hold more than limit characters; then Skipped(-1), the end."""
    for line in lines:
        if not isinstance(line, Skipped):
            limit -= len(line) + 1
            if limit < 0:
                yield Skipped(-1)
                return
        yield line


def _statements(lines):
    """Journal lines -> (first line number, [lines], number of lines) per statement: a Jrn.* line with its '_'
    continuations (at most JRN_CONT of them kept, all counted), or one other line. A Skipped passes through as
    (0, Skipped, 0)."""
    cur, start, n = None, 0, 0
    for i, line in enumerate(lines, 1):
        if isinstance(line, Skipped):
            if cur is not None:
                yield start, cur, n
                cur = None
            yield 0, line, 0
            continue
        if cur is not None:
            n += 1
            if len(cur) < JRN_CONT:
                cur.append(line)
            if not line.rstrip().endswith("_"):
                yield start, cur, n
                cur = None
            continue
        if re.match(r"^\s*Jrn\.", line) and line.rstrip().endswith("_"):
            cur, start, n = [line], i, 1
            continue
        yield i, [line], 1
    if cur is not None:
        yield start, cur, n


def _joined(st):
    return " ".join(re.sub(r"\s*_\s*$", "", s.strip()) for s in st)


def _titles_out(s):
    """Quoted and bracketed text (a document or view title can be there) as \u2026, an unclosed one too."""
    s = re.sub(r'"[^"]*"', '"\u2026"', s)
    s = re.sub(r"'[^'\n]*'", "'\u2026'", s)
    s = re.sub(r"\[[^\]]*\]", "[\u2026]", s)
    for q in "\"'[":   # one left open (the line was cut, or a title holds an apostrophe): all after it
        if (s.count(q) % 2 if q != "[" else s.rfind("[") > s.rfind("]")):
            s = s[:s.rfind(q) + 1] + "\u2026"
    return s


def journal_extract(lines, keep=None):
    """The allowed lines of a Revit journal: Build/Release, directives Version/DebugMode/ScreenResolution, command ids,
    TaskDialog ids, license state, start/end markers and lines that report a failure (keep: an extra regex, e.g. the
    signature catalog). Everything else becomes '... N lines dropped'; add-in lines become a count. Read as a stream,
    with bounds: it keeps the header lines among the first 60 it keeps and its last JOURNAL_MAX lines, JRN_CONT lines
    of a statement, and reads at most 2 x JOURNAL_READ characters. A Skipped in lines: a part not read."""
    dropped, addins, errors, vendors = 0, 0, 0, set()
    head, tail, kept = [], collections.deque(maxlen=JOURNAL_MAX), [0]

    def emit(s):
        if kept[0] < 60 and s.startswith(("' Build", "' Release", "Jrn.Directive")):
            head.append(s)
        kept[0] += 1
        tail.append(s)

    def put(s):
        nonlocal dropped
        if dropped:
            emit("\u2026 %d lines dropped" % dropped)
            dropped = 0
        emit(s)
    for _, st, n in _statements(_budget(lines, 2 * JOURNAL_READ)):
        if isinstance(st, Skipped):
            put("\u2026 the rest of the journal not read" if st.n < 0 else
                "\u2026 %d KB of the journal not read" % (st.n // 1024))
            continue
        one = st[0]
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
            elif kind == "directive" and q and q[0].lower() in JRN_KEEP_DIRECTIVES and n < JRN_CONT:
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
            if len(s) >= READ_LINE:   # cut by the reader: no part of a value at its end
                s = _trim_cut(s)
            mark = re.match(r"^\s*'[A-Z]?", s)
            mark = mark.group(0) if mark else ""
            put((mark + _titles_out(s[len(mark):])).strip())
        else:
            dropped += 1
    if dropped:
        emit("\u2026 %d lines dropped" % dropped)
    if addins:
        emit("add-in lines: %d (%d errors); Autodesk vendor ids: %s" % (addins, errors,
                                                                      ", ".join(sorted(vendors)) or "none"))
    if kept[0] > JOURNAL_MAX:
        return head + ["\u2026 %d kept lines cut" % (kept[0] - JOURNAL_MAX)] + list(tail)
    return list(tail)


def journal_file(path, keep=None):
    """journal_extract for a journal file of any size: all of it up to JOURNAL_READ bytes, else its first
    JOURNAL_READ / 8 bytes (Build, Release, the directives) and its last bytes, a note for the part in between."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return []
    if size <= JOURNAL_READ:
        return journal_extract(bottleread.read_lines(path, JOURNAL_READ), keep)
    first = JOURNAL_READ // 8
    start = size - (JOURNAL_READ - first)
    return journal_extract(itertools.chain(bottleread.read_lines(path, first), [Skipped(start - first)],
                                           bottleread.read_lines(path, start=start)), keep)


# The lines of a log that may go into a report: those that report an error or a crash. (a literal every match holds:
# the fast search through a big log; the pattern that decides, on the whole line, or None for the literal itself).
# Our own and the installer's failure lines, then the warn signatures of tools/signatures.py: one list with the catalog
ERROR_LINE = (
    ("Error ", r"\bError \d{4}\b"),                       # MSI and Windows Installer error codes
    ("returned actual error code", None),                 # MSI: a custom action failed
    ("!!", r"^\s*!!"),                                    # our scripts' own failure lines
    ("exit=", r"^\s+\S+\s+exit=(?!0(?!\S)|skip(?!\S))\S"),   # a summary line of a step that did not end with 0
) + signatures.error_lines()   # MSI Return value 3, wine: Unhandled, ReportEventW, unrecoverable error, ...
ERROR_RX = re.compile("|".join(collections.OrderedDict.fromkeys(p or re.escape(lit) for lit, p in ERROR_LINE)))
ERROR_LITS = tuple(lit.encode() for lit, _ in ERROR_LINE)


def _numbered(lines):
    n = 0
    for x in lines:
        if isinstance(x, tuple):
            n, x = x
        else:
            n += 1
        yield n, x


CUT_MARK = " \u2026[cut]"


def _trim_cut(line):
    """A line the reader cut (READ_LINE characters) is left out, but for a mark: its cut end may hold the first words
    of a value of several words (a denylisted project name) that the redactor and the gate no longer recognize."""
    return "\u2026 a line too long to check was left out (%d+ characters)" % len(line)


def _cut_line(ln):
    """A redacted line cut to LINE_MAX characters, never inside a placeholder."""
    if len(ln) <= LINE_MAX:
        return ln
    cut = ln[:LINE_MAX - len(CUT_MARK)]
    k = cut.rfind("<")
    if k >= 0 and ">" not in cut[k:] and TOKEN.match(ln, k):
        cut = cut[:k]
    return cut + CUT_MARK


def error_extract(lines, limit=ERROR_LINES):
    """The lines that report an error or a crash (ERROR_LINE), each as 'line N: text' and nothing around it: no
    context, no tail. At most `limit`: the first and the last half when there are more. lines: str or (number, str).
    A line is not cut here: it is redacted whole, then cut (_cut_line); one the reader cut loses its last word."""
    head, tail, n = [], collections.deque(maxlen=limit - limit // 2), 0
    for i, line in _numbered(lines):
        if ERROR_RX.search(line):
            n += 1
            line = line.rstrip("\r\n")
            s = "line %d: %s" % (i, _trim_cut(line) if len(line) >= READ_LINE else line)
            if len(head) < limit // 2:
                head.append(s)
            else:
                tail.append(s)
    more = n - len(head) - len(tail)
    return head + (["\u2026 %d more error line%s not kept" % (more, "" if more == 1 else "s")] if more else []) + \
        list(tail)


MSI_PROP = re.compile(r"^\s*Property\(([A-Z])\):\s*([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*?)\s*$")
MSI_KEEP = ("productversion", "productcode", "adlm_prodkey", "revitlanguage", "transforms")
MSI_VALUE = re.compile(r"[A-Za-z0-9_.{}:;@ -]{0,120}")


def msi_extract(lines, limit=ERROR_LINES):
    """An MSI log: its error lines (Return value 3, Error NNNN, returned actual error code...) and the allowed
    properties as fields, a value that is not a plain one shown as '(not shown)'. Every other line, Property(S|C)
    lines too, stays out. [] when nothing failed."""
    props = collections.OrderedDict()

    def rest():
        for i, line in enumerate(lines, 1):
            m = MSI_PROP.match(line)
            if not m:
                yield i, line
            elif m.group(2).lower() in MSI_KEEP and m.group(2).lower() not in props:
                v = m.group(3) if MSI_VALUE.fullmatch(m.group(3)) else "(not shown)"
                props[m.group(2).lower()] = "Property(%s): %s = %s" % (m.group(1), m.group(2), v)
    out = error_extract(rest(), limit)
    if out and props:
        out += ["--- properties ---"] + list(props.values())
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
GAP = object()   # cxlog_file: from here on, only the lines the fast search found


def cxlog_extract(lines, limit=ERROR_LINES):
    """A CrossOver log: never its header (Environment, CXConfig->read, Starting/Command); only its fields (CrossOver
    version, mode, backend, debug channels, PATH as a count), each from the newest header that has it (a launch writes
    a full header and then a short one), then its error lines (wine: Unhandled ..., err:eventlog:ReportEventW,
    Assertion failed...) with their line numbers. lines: str or (number, str); after GAP a line that looks like a
    header line is taken for one."""
    st = {"fields": {}, "sessions": 0, "state": "start"}

    def body():
        n = 0
        for x in lines:
            if x is GAP:
                st["state"] = "unknown"
                continue
            n, line = x if isinstance(x, tuple) else (n + 1, x)
            state = st["state"]
            if CX_HEADER.match(line) or (state == "start" and CX_HEADERISH.match(line)):
                state = "header"
                st["sessions"] += 1
            elif state == "header" and CX_WINE.match(line):
                state = "body"
            elif state == "start":
                state = "body"
            st["state"] = state
            if state == "header":
                for k, rx in CX_FIELDS:
                    m = rx.match(line)
                    if m:
                        st["fields"][k] = m.group(1)
                m = CX_PATH.match(line)
                if m:
                    st["fields"]["PATH"] = "%d entries" % len([p for p in m.group(1).split(":") if p])
            elif not (state == "unknown" and CX_HEADERISH.match(line)):
                yield n, line
    errors = error_extract(body(), limit)
    fields, sessions = st["fields"], st["sessions"]
    out = ["wine.cxlog: %d header%s; their fields:" % (sessions, "" if sessions == 1 else "s")]
    fields.setdefault("backend", "default")
    for k in ("Product version", "Mode", "backend", "CX_DEBUGMSG", "WINEDEBUG", "PATH"):
        if k in fields:
            out.append("  %s: %s" % (k, fields[k]))
    out.append("Error lines: %s" % ("none" if not errors else "%d" % len([e for e in errors if e.startswith("line ")])))
    return out + errors


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


def _scan(path, start=0, first=1, lits=ERROR_LITS):
    """(number, line) of each line from byte `start` (line `first`) on that holds one of the literals: a big log
    searched in blocks (bytes.find, fast), read up to the size it had when opened; error_extract decides on each."""
    try:
        f = open(path, "rb")
    except OSError:
        return
    with f:
        left = min(os.fstat(f.fileno()).st_size, SCAN_MAX) - start
        f.seek(start)
        n, carry = first, b""
        while left > 0 or carry:
            block = f.read(min(SCAN_BLOCK, left)) if left > 0 else b""
            left = left - len(block) if block else 0   # a file cut short while read: what was read is all
            buf = carry + block
            cut = buf.rfind(b"\n") + 1 if left > 0 and block else len(buf)
            if cut == 0 and len(buf) < 4 * SCAN_BLOCK:
                carry = buf   # no line end yet: read on
                continue
            data, carry = buf[:cut or len(buf)], buf[cut or len(buf):]
            starts = set()
            for lit in lits:
                i = data.find(lit)
                while i >= 0:
                    starts.add(data.rfind(b"\n", 0, i) + 1)
                    e = data.find(b"\n", i)
                    i = data.find(lit, e) if e >= 0 else -1
            pos = 0
            for s in sorted(starts):
                n += data.count(b"\n", pos, s)
                pos = s
                e = data.find(b"\n", s)
                yield n, data[s:(len(data) if e < 0 else e)][:16000].decode("utf-8", "replace").rstrip("\r")[:4000]
            n += data.count(b"\n", pos)
            if not block:
                break


def _utf16(path):
    try:
        with open(path, "rb") as f:
            return _is_utf16(f.read(4096))
    except OSError:
        return False


def error_file(path, limit=ERROR_LINES):
    """error_extract for a log file of any size."""
    return error_extract(_utf16_lines(path) if _utf16(path) else _scan(path), limit)


def cxlog_file(path, limit=ERROR_LINES):
    """cxlog_extract for a file of any size: its first lines (the header) one by one, then the lines the fast search
    finds."""
    if _utf16(path):
        return cxlog_extract(_utf16_lines(path), limit)
    try:
        with open(path, "rb") as f:
            raw = f.read(1 << 20)
    except OSError:
        return []
    parts = raw.split(b"\n")
    if len(parts) > CX_HEAD_LINES or (len(raw) == 1 << 20 and len(parts) > 1):
        parts = parts[:min(CX_HEAD_LINES, len(parts) - 1)]   # whole lines only
        off = sum(len(p) + 1 for p in parts)
    else:
        off = len(raw)
    head = [(i, p.decode("utf-8", "replace").rstrip("\r")[:4000]) for i, p in enumerate(parts, 1)]
    if off >= len(raw) and len(raw) < 1 << 20:
        return cxlog_extract(head, limit)
    return cxlog_extract(itertools.chain(head, [GAP], _scan(path, off, len(parts) + 1)), limit)


def _whole(lines):
    """Lines as read, one the reader cut without the part of a value at its end (_trim_cut)."""
    return [_trim_cut(ln) if len(ln) >= READ_LINE else ln for ln in lines]


def _text(path, keep="head", limit=MEMBER_MAX * 2):
    lines = _whole(_lines(path)) if keep == "head" else _whole(_tail(path, 100000)[0])
    text = "\n".join(lines)
    return text[:limit] if keep == "head" else text[-limit:]


# ---------------------------------------------------------------------------------------------------------------
# Building the report
# ---------------------------------------------------------------------------------------------------------------
# logs/<bottle>/<time>-<kind>; a second run in the same second: <time>-<kind>-2 (run_dir_new), <time>-2-<kind> before
RUN_RE = re.compile(r"^(\d{8}-\d{6})(?:-(\d+))?-([a-z]+)(?:-(\d+))?$")
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
                out.append(((m.group(1), int(m.group(4) or m.group(2) or 1)), m.group(3), p))
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

    def add(self, name, what, text, src=None, keep="tail", rel=None, cut=None, age=None, per_line=False):
        """per_line: the gate checks each line on its own and a line that fails it is left out, not the member."""
        self.items.append({"name": name, "what": what, "text": text, "src": src, "keep": keep, "rel": rel,
                           "cut": cut, "age": age, "per_line": per_line})


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

    def take(fname, name, what, text, keep="tail", cut=None, per_line=False):
        used.add(fname)
        c.add(name, what, text, src=c.label(os.path.join(d, fname)), keep=keep, rel=d, cut=cut, age=age,
              per_line=per_line)

    def errors(fname, name, ex, what, none):   # a log's error lines, or why nothing of it is in the report
        if ex:
            take(fname, name, what, "\n".join(ex), keep="head", per_line=True)
        else:
            used.add(fname)
            c.skipped.append((c.label(os.path.join(d, fname)), none))
    if kind in ("install", "steps", "addins"):
        for f in ("summary.txt", "failed.txt"):
            if _regular(os.path.join(d, f)):
                take(f, "%s/%s" % (kind, f), "%s of the %s" % (f, label), _text(os.path.join(d, f)), keep="head")
        failed = _failed_steps(d)
        c.facts.setdefault("failed", {})[kind] = failed
        for s in failed + ["action-" + a for a in _failed_actions(d)]:
            f = s + ".log"
            if _regular(os.path.join(d, f)):
                errors(f, "%s/%s-errors.txt" % (kind, s), error_file(os.path.join(d, f)), "error lines of %s" % f,
                       "a failed step's log without an error line: nothing to add")
        for f in _listdir(d):
            if f.endswith(".msi.log") and SAFE_NAME.match(f) and _regular(os.path.join(d, f)):
                errors(f, "%s/%s-msi-errors.txt" % (kind, f[:-len(".msi.log")]),
                       msi_extract(_lines(os.path.join(d, f))), "error lines of %s" % f,
                       "an MSI log without a failure: nothing to add")
    elif kind == "debug":
        p = os.path.join(d, "wine.cxlog")
        if _regular(p):
            take("wine.cxlog", "debug/wine-cxlog.txt", "header fields and error lines of wine.cxlog",
                 "\n".join(cxlog_file(p)), keep="head", per_line=True)
        p = os.path.join(d, "stdout.log")
        if _regular(p):
            errors("stdout.log", "debug/stdout-errors.txt", error_file(p), "error lines of stdout.log",
                   "stdout.log without an error line: nothing to add")
    elif kind == "test":
        p = os.path.join(d, "result.json")
        if _regular(p):
            take("result.json", "test/result.json", "result of the test run", _text(p), keep="head")
    for f in _listdir(d):
        if f not in used:
            c.skipped.append((c.label(os.path.join(d, f)), _why_not(f, os.path.join(d, f))))


def _take_trackpad(c, data):
    """The menu bar app's trackpad helper (docs/how-it-works.md): its log and the one before it, each to its last 500
    lines, and its state. The helper writes no window titles and no coordinates; paths and names are redacted here as
    everywhere."""
    for rel, name, what in (("logs/trackpad.log", "trackpad/trackpad.log", "log of the trackpad helper"),
                            ("logs/trackpad.log.1", "trackpad/trackpad.log.1", "earlier log of the trackpad helper")):
        p = os.path.join(data, rel)
        if _regular(p):
            lines, cut = _tail(p, 500)
            c.add(name, what, "\n".join(_whole(lines)), src=c.label(p), cut="to its last 500 lines" if cut else None)
    p = os.path.join(data, "trackpad", "state.json")
    if _regular(p):
        c.add("trackpad/state.json", "state of the trackpad helper", _text(p), src=c.label(p), keep="head")


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
            text = json.dumps(c.facts["doctor"], indent=1, ensure_ascii=False)   # a field a line: none is cut
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
                c.add("run/events.ndjson", "events of the run", "\n".join(_whole(lines)), src=c.label(ev),
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
    _take_trackpad(c, data)
    if bdir:
        rn = os.path.join(bdir, "revit-macos", "runs.ndjson")
        if _regular(rn):
            lines, cut = _tail(rn, 2000)
            c.add("bottle/runs.ndjson", "run records of the bottle", "\n".join(_whole(lines)),
                  src="bottle: runs.ndjson", cut="to its last 2000 records" if cut else None)
            for ln in reversed(lines):
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get("kind") == "install":
                    c.facts["last"] = r
                    break
        wl = os.path.join(bdir, "revit-macos", "wineserver.log")   # scripts/watch-server.pl
        if _regular(wl):
            lines, cut = _tail(wl, 300)
            c.add("bottle/wineserver.log", "the bottle's wineserver: its messages, starts and ends",
                  "\n".join(_whole(lines)), src="bottle: wineserver.log", cut="to its last 300 lines" if cut else None)
        wj = os.path.join(bdir, "revit-macos", "wineserver.last")
        if _regular(wj):
            c.add("bottle/wineserver-last.json", "how the bottle's last wineserver ended", _text(wj),
                  src="bottle: wineserver.last", keep="head")
        if year:
            p = revit_ini_paths(bdir, year)[0]
            if _regular(p):
                allowed = _ini_allowed(p)
                if allowed:
                    c.add("bottle/revit-ini.txt", "allowed keys of Revit.ini", "\n".join(allowed),
                          src="bottle: Revit.ini", keep="head")
            j = bottleread.newest_journal(bdir, year)
            if j and _regular(j):
                ex = journal_file(j, keep=signatures.journal_rx())
                for s in ex[:80]:
                    m = re.match(r"^' (Build|Release):\s*(.+)$", s)
                    if m:
                        c.facts[m.group(1).lower()] = m.group(2).strip()
                c.add("bottle/journal-extract.txt", "extract of the newest Revit journal", "\n".join(ex),
                      src="bottle: newest Revit journal", cut="to its allowed lines",
                      age=("Revit journal", os.path.getmtime(j)))
    return c


MATERIAL_BOTTLE_RX = re.compile(r"(?:\blogs" + SEP + r"([^\\/\s\"'<>|]{1,255})" + SEP + r"\d{8}-\d{6}|\bBottles" + SEP +
                                r"([^\\/\s\"'<>|]{1,255})(?=" + SEP + r"|[\"'\s]|$))", re.M)
BOTTLE_KEYS = ("bottle", "copy", "source")


def _json_values(x, out):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in BOTTLE_KEYS and isinstance(v, str):
                out.append(v)
            else:
                _json_values(v, out)
    elif isinstance(x, list):
        for v in x:
            _json_values(v, out)


def _material_bottles(c):
    """The bottle names in what was collected: doctor's check ids, the bottle fields of its JSON (test result, run
    records, events), paths through logs/<bottle>/<run> or Bottles/<bottle>."""
    out = []
    doc = c.facts.get("doctor")
    checks = doc.get("checks") if isinstance(doc, dict) else None
    for x in checks if isinstance(checks, list) else []:
        m = re.match(r"^bottles\.(?:clone\.)?(.+)$", str(x.get("id", ""))) if isinstance(x, dict) else None
        if m and m.group(1) != "none":
            out.append(m.group(1))
    for it in c.items:
        text = it["text"]
        out += [a or b for a, b in MATERIAL_BOTTLE_RX.findall(text)]
        s = text.strip()
        for doc in ([s] if s[:1] in "{[" and s[-1:] in "}]" else []) + \
                [ln for ln in text.split("\n") if ln.strip()[:1] == "{"]:
            try:
                _json_values(json.loads(doc), out)
            except (ValueError, RecursionError):
                pass
    return out


def _caps(text, keep):
    """Lines of at most LINE_MAX characters, at most MEMBER_MAX bytes (the head or the tail) -> (bytes, cut)."""
    cut, lines = None, []
    for ln in text.split("\n"):
        if len(ln) > LINE_MAX:
            ln, cut = _cut_line(ln), "long lines cut"
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
                word = LABELS[cls][1]
                parts.append("%d %s%s" % (n, word, "" if n == 1 else "es" if word.endswith("s") else "s"))
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
    sha = _git(root, "rev-parse", "--short", "HEAD").strip()
    if not sha:
        return "unknown"
    dirty = _git(root, "status", "--porcelain", "--untracked-files=no").strip()
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
    for it in kept:
        if it.get("dropped"):
            out.append("Left out: %d line%s of the %s \u2014 personal data that could not be removed."
                       % (it["dropped"], "" if it["dropped"] == 1 else "s", it["what"]))
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
        cut = "; cut " + it["cut"] if it.get("cut") else ""
        dropped = "; %d line%s left out" % (it["dropped"], "" if it["dropped"] == 1 else "s") \
            if it.get("dropped") else ""
        out.append("  %s \u2014 %s%s%s%s" % (it["name"], it["what"], src, cut, dropped))
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
    bottle when not given (tests pass a synthetic one); either way, every bottle the collected parts name and the
    Autodesk identity of each bottle are added to it (learn_bottles) before anything is redacted."""
    now = time.time() if now is None else now
    year = str(year) if year else None
    bdir = _bottle_dir(bottles, bottle)
    if identity is None:
        identity = collect_identity(root, data, bdir, year, bottle)
    c = _collect(root, data, bdir, year, bottle, run, doctor_json, now)
    learn_bottles(identity, data, bottles, _material_bottles(c))
    ex = set(exclude or ())
    kept, left, counts = [], [], collections.Counter()
    for it in c.items:
        if ex & {it["name"], os.path.basename(it["name"]), os.path.basename(it.get("src") or "")}:
            c.skipped.append((it.get("src") or it["name"], "left out on request (--exclude)"))
            continue
        text, n = redact(it["text"], identity, rel=it.get("rel"))
        if it.get("per_line"):   # a log's lines: each one, redacted whole and then cut, passes the gate or is left out
            lines = text.split("\n")
            if any(len(ln) > LINE_MAX for ln in lines):
                lines = [_cut_line(ln) for ln in lines]
                it["cut"] = ", ".join(x for x in (it.get("cut"), "long lines cut") if x)
            ok = [ln for ln in lines if not gate(ln.encode("utf-8"), identity, it["name"])]
            it["dropped"] = len(lines) - len(ok)
            if it["dropped"]:
                ok.append("\u2026 %d line%s left out: personal data that could not be removed"
                          % (it["dropped"], "" if it["dropped"] == 1 else "s"))
            text = "\n".join(ok)
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
            ident = collect_identity(a.root, data, _bottle_dir(a.bottles, a.bottle), a.year, a.bottle, a.bottles)
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
