# SPDX-License-Identifier: MIT
"""Unit tests for tools/signatures.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every log line here is made up for the test: no real log, no Autodesk or Microsoft file, no personal value."""
import importlib.util, json, os, re, subprocess, sys, tempfile, unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TOOLS = os.path.join(REPO, "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sg = load("signatures")
FILE = {"cxlog": "wine.cxlog", "journal": "journal.0042.txt", "steplog": "rvt.log", "msilog": "rvt.msi.log"}
# id -> (a line it fires on, a line of the same log it stays silent on: noise healthy sessions have)
SAMPLES = {
    "wine-crash": ("wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001000 "
                   "(thread 0040), starting debugger...",
                   "1.234:0030:0040:warn:seh:dispatch_exception code=c0000005 flags=0 addr=0000000140001000"),
    "netfx-80131506": ('1.234:0030:0040:err:eventlog:ReportEventW L"Application: Revit.exe internal error in the '
                       '.NET Runtime at IP 0000 (0000) with exit code 80131506."',
                       "1.234:0030:0040:fixme:combase:RoGetParameterizedTypeInstanceIID stub"),
    "dotnet-fatal": ('1.234:0030:0040:err:eventlog:ReportEventW L"Application: Revit.exe Description: The process '
                     'was terminated due to an unhandled exception."',
                     "1.234:0030:0040:err:ole:ensure_mta Failed, hr 0x800401f0"),
    "wine-missing-function": ("wine: Call from 00006FFFFFC3A1B4 to unimplemented function "
                              "USER32.dll.SetDialogControlDpiChangeBehavior, aborting",
                              "1.234:0030:0040:fixme:win:SetWindowDisplayAffinity stub"),
    "metal-assertion": ("MTLTextureDescriptor has invalid pixelFormat (0).",
                        "1.234:0030:0040:fixme:win:shm_surface_set_clip"),
    "assertion": ("Assertion failed: (0), function user_check_not_lock, file sysparams.c, line 323.",
                  "1.234:0030:0040:err:sync:RtlLeaveCriticalSection section 0000000012345678 is not acquired"),
    "ecdsa-verify": ('1.234:0030:0040:warn:seh:dispatch_exception "[ncrypt-shim] VerifySignature(32 bytes) -> '
                     '0xc000a000\\n"',
                     '1.234:0030:0040:warn:debugstr:OutputDebugStringA "[ncrypt-shim] VerifySignature(32 bytes) -> '
                     '0xc000a000\\n"'),
    "journal-unrecoverable": ("' 0:< DBG_WARN: An unrecoverable error has occurred.",
                              "' 0:< DBG_WARN: ODIS SDK failed to get the AIAssistant installed location"),
    "journal-exception": ("' 0:< Exception occurred in OGS", "' 0:< DBG_WARN: Unable to create D2D render target"),
    "journal-capture-crash": ("' 0:< captureTryCrash 0xc0000005",
                              "' 0:< DBG_WARN: Register DragDrop event failed: -2147221246"),
    "journal-assertion": ("' 0:< Assertion failed: line 52 of d:\\ship\\pipeline\\dataintegrity.cpp",
                          "' 0:< License mode: User"),
    "licensing-no-answer": ("the Autodesk licensing service does not answer, so RVT.msi would fail",
                            "AdskLicensingService has been upgraded successfully"),
    "licensing-install-failed": ("the licensing installer returned 5",
                                 "LIC-INST-ERROR-1053. Starting Windows service during new installation failed: "
                                 "Calling system API failed, (error code 1053)"),
    "msi-failed": ("Action ended 12:00:01: INSTALL. Return value 0.", "Action ended 12:00:01: INSTALL. Return value 1."),
}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, name, lines, raw=None):
        p = os.path.join(self.d, name)
        with open(p, "wb") as f:
            f.write(raw if raw is not None else ("\n".join(lines) + "\n").encode("utf-8"))
        return p


class Catalog(unittest.TestCase):
    def test_shape(self):
        self.assertTrue(10 <= len(sg.CATALOG) <= 15, len(sg.CATALOG))
        self.assertEqual(len(sg.BY_ID), len(sg.CATALOG), "ids are unique")
        for s in sg.CATALOG:
            self.assertIn(s.where, sg.WHERE, s.id)
            self.assertIn(s.level, ("warn", "info"), s.id)
            self.assertTrue(s.years == "all" or set(s.years) <= {2020, 2023, 2024, 2025, 2026, 2027}, s.id)
            self.assertTrue(s.meaning and s.source and s.lits, s.id)
            if s.level == "warn":
                self.assertTrue(s.fix or s.doc, "a warning says what to do: %s" % s.id)
            json.dumps(s.json())

    def test_words_of_the_user_pages(self):
        for s in sg.CATALOG:
            for field in (s.meaning, s.fix, s.source):
                self.assertNotRegex(field, r"\b[A-Z]{2}-[A-Z]?\d|internal/|docs/journal|\bjournal \d{4}-", s.id)
                self.assertNotRegex(field, r"n't\b|\b(?:simply|just|seamless)\b", s.id)
                self.assertTrue(all(c.isascii() for c in field), s.id)
            for field in (s.meaning, s.fix):
                self.assertNotIn("shim", field.lower(), "user pages say fix, not shim: %s" % s.id)

    def test_doc_anchors_exist(self):
        with open(os.path.join(REPO, "docs", "troubleshooting.md"), encoding="utf-8") as f:
            heads = re.findall(r"^#+ (.+)$", f.read(), re.M)
        anchors = {re.sub(r"[^a-z0-9 -]", "", h.lower()).replace(" ", "-") for h in heads}
        for s in sg.CATALOG:
            if s.doc:
                self.assertIn(s.doc, anchors, s.id)

    def test_every_signature_has_samples(self):
        self.assertEqual(sorted(SAMPLES), sorted(sg.BY_ID))
        for sid, (fire, benign) in SAMPLES.items():   # the fast search of a big log finds the line by a literal
            self.assertTrue(any(lit in fire for lit in sg.BY_ID[sid].lits), sid)
            self.assertTrue(sg.BY_ID[sid].rx.search(fire) and not sg.BY_ID[sid].rx.search(benign), sid)

    def test_one_place_for_the_journal_patterns(self):
        smoke = load("smoke")
        self.assertEqual([n for n, _ in smoke.STRONG],
                         ["unrecoverable error", "Exception occurred", "captureTryCrash", "Assertion failed"])
        report = load("report")
        for s in sg.CATALOG:
            if s.level == "warn":
                for lit in s.lits:
                    self.assertIn(lit.encode(), report.ERROR_LITS, s.id)
        self.assertTrue(report.ERROR_RX.search(SAMPLES["msi-failed"][0]))
        self.assertTrue(report.ERROR_RX.search(SAMPLES["metal-assertion"][0]))
        self.assertFalse(report.ERROR_RX.search(SAMPLES["ecdsa-verify"][0]), "an info count is no error line")


class Scan(Base):
    def test_each_fires_and_stays_silent(self):
        for sid, (fire, benign) in SAMPLES.items():
            s = sg.BY_ID[sid]
            year = 2020 if sid == "netfx-80131506" else 2025
            p = self.log(FILE[s.where], [benign] * 3 + [fire] + [benign])
            r = sg.scan_file(p, year=year)
            self.assertEqual(r["where"], s.where)
            if s.level == "warn":
                self.assertEqual(list(r["hits"]), [sid], sid)
                self.assertEqual(r["hits"][sid]["lines"], [4], sid)
            else:
                self.assertEqual(r["hits"], {}, sid)
                self.assertEqual(r["metrics"], {sid: {"failed": 1, "passed": 0}}, sid)
            q = self.log(FILE[s.where], [benign] * 5)
            self.assertEqual(sg.scan_file(q, year=year)["hits"], {}, sid)

    def test_healthy_noise_of_each_log_is_silent(self):
        for where in sg.WHERE:
            noise = [b for sid, (_, b) in SAMPLES.items() if sg.BY_ID[sid].where == where]
            r = sg.scan_file(self.log(FILE[where], noise * 50), year=2027)
            self.assertEqual((r["hits"], r["lines"]), ({}, len(noise) * 50), where)

    def test_process_by_its_thread_id_only(self):
        lines = ['1.0:0030:0031:trace:loaddll:build_module Loaded L"C:\\\\Program Files\\\\Autodesk\\\\Revit 2025\\\\'
                 'Revit.exe" at 0000000140000000: native',
                 '1.1:0050:0051:trace:loaddll:build_module Loaded L"C:\\\\Program Files\\\\Autodesk\\\\Revit 2025\\\\'
                 'AdPreviewGenerator.exe" at 0000000140000000: native',
                 "1.2:0030:0040:warn:seh:dispatch_exception code=c0000005 flags=0 addr=0000000140001000",
                 "1.3:0050:0051:warn:seh:dispatch_exception code=e06d7363 flags=1 addr=0000000140002000",
                 SAMPLES["wine-crash"][0],                                         # thread 0040: Revit.exe
                 "1.4:0050:0051:warn:seh:dispatch_exception code=e06d7363 flags=1 addr=0000000140002000",
                 "wine: Unhandled page fault on read access to 0 at address 1 (thread 0099), starting debugger...",
                 "wine: Unhandled exception 0xc0000409 at address 1"]              # no thread: nobody is guessed
        r = sg.scan_file(self.log("wine.cxlog", lines), year=2025)
        self.assertEqual(r["hits"]["wine-crash"]["count"], 3)
        self.assertEqual(r["hits"]["wine-crash"]["details"], ["Revit.exe", "process unknown"])
        self.assertEqual(r["hits"]["wine-crash"]["lines"], [5, 7, 8])

    def test_missing_function_named(self):
        r = sg.scan_file(self.log("stdout.log", [SAMPLES["wine-missing-function"][0]]), year=2026)
        self.assertEqual(r["hits"]["wine-missing-function"]["details"], ["USER32.dll.SetDialogControlDpiChangeBehavior"])

    def test_ecdsa_counted_once_a_check(self):
        fail, dup = SAMPLES["ecdsa-verify"]
        ok = fail.replace("0xc000a000", "0x0")
        r = sg.scan_file(self.log("wine.cxlog", [fail, dup, fail, ok, dup, fail, ok]), year=2024)
        self.assertEqual(r["metrics"], {"ecdsa-verify": {"failed": 3, "passed": 2}})
        self.assertEqual(r["hits"], {})

    def test_year_and_first_match(self):
        line = SAMPLES["netfx-80131506"][0]
        self.assertEqual(list(sg.scan_file(self.log("wine.cxlog", [line]), year=2020)["hits"]), ["netfx-80131506"])
        self.assertEqual(list(sg.scan_file(self.log("wine.cxlog", [line]), year=2025)["hits"]), ["dotnet-fatal"])

    def test_journal_without_case(self):
        r = sg.scan_file(self.log("journal.0001.txt", ["' 0:< UNRECOVERABLE ERROR", "' 0:< exception OCCURRED"]))
        self.assertEqual(sorted(r["hits"]), ["journal-exception", "journal-unrecoverable"])

    def test_utf16_msi_log(self):
        text = "Action start 12:00:00: INSTALL.\r\nAction ended 12:00:01: INSTALL. Return value 0.\r\n"
        p = self.log("x.msi.log", None, raw=b"\xff\xfe" + text.encode("utf-16-le"))
        self.assertEqual(sg.scan_file(p)["hits"]["msi-failed"]["lines"], [2])
        p = self.log("y.msi.log", None, raw=text.replace("0.", "1.").encode("utf-16-le"))   # no BOM
        self.assertEqual(sg.scan_file(p)["hits"], {})

    def test_hits_capped_count_exact(self):
        r = sg.scan_file(self.log("wine.cxlog", [SAMPLES["assertion"][0]] * 50))
        self.assertEqual(r["hits"]["assertion"]["count"], 50)
        self.assertEqual(r["hits"]["assertion"]["lines"], list(range(1, sg.HITS_MAX + 1)))

    def test_binary_and_long_lines(self):
        raw = (b"\x00\xff\xfe binary \x00\n" + b"y" * 300000 + b" Assertion failed in a long line\n" +
               SAMPLES["wine-crash"][0].encode() + b"\n")
        r = sg.scan_file(self.log("stdout.log", None, raw=raw))
        self.assertEqual(r["hits"]["wine-crash"]["lines"], [3])   # a long line is cut: its end is not read
        self.assertNotIn("assertion", r["hits"])

    def test_a_big_file_is_read_from_its_end(self):
        lines = ["1.0:0030:0040:trace:module:load %05d %s" % (i, "z" * 40) for i in range(5000)]
        lines[10] = SAMPLES["assertion"][0]
        lines[4989] = SAMPLES["wine-crash"][0]
        p = self.log("wine.cxlog", lines)
        r = sg.scan_file(p, lines_max=1000)
        self.assertEqual(list(r["hits"]), ["wine-crash"])
        self.assertEqual(r["hits"]["wine-crash"]["lines"], [4990])   # the true line number
        self.assertEqual((r["first_line"], r["lines"], r["cut"]), (4001, 1000, None))   # its last 1000 lines
        self.assertGreater(r["start"], 0)
        lines += ["1.0:0030:0040:trace:module:load %s" % ("w" * 3000)] * 60 + [SAMPLES["assertion"][0]]
        r = sg.scan_file(self.log("long.cxlog", lines), lines_max=1000)   # long lines at the end: still its end
        self.assertEqual((sorted(r["hits"]), r["first_line"], r["lines"], r["cut"]), (["assertion", "wine-crash"], 4062, 1000, None))
        r = sg.scan_file(p, lines_max=1000, from_start=True)
        self.assertEqual((list(r["hits"]), r["cut"], r["lines"]), (["assertion"], "lines", 1000))
        self.assertEqual(sorted(sg.scan_file(p)["hits"]), ["assertion", "wine-crash"])

    def test_size_fixed_when_opened(self):
        first = "one\n" + SAMPLES["wine-crash"][0] + "\n"
        p = self.log("wine.cxlog", None, raw=(first + "two\n" + SAMPLES["assertion"][0] + "\n").encode())
        real = os.fstat

        class Opened:   # what the file held when opened: the rest was written after
            def __init__(self, st):
                self.st_size = len(first)
        os.fstat = lambda fd: Opened(real(fd))
        try:
            r = sg.scan_file(p)
        finally:
            os.fstat = real
        self.assertEqual((list(r["hits"]), r["lines"]), (["wine-crash"], 2))

    def test_no_file_or_other_kind(self):
        self.assertEqual(sg.scan_file(os.path.join(self.d, "gone.cxlog"))["hits"], {})
        self.assertIsNone(sg.scan_file(self.log("notes.txt", ["Assertion failed"]))["where"])
        self.assertEqual(sg.where_of("AdskLicensing-install.log"), "steplog")
        self.assertEqual(sg.where_of("rvt.msi.log"), "msilog")
        self.assertEqual(sg.where_of("stdout.log"), "cxlog")

    def test_cli_prints_no_log_text(self):
        p = self.log("wine.cxlog", ["secretword " + SAMPLES["wine-crash"][0]])
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "signatures.py"), "scan", p, "--json"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)[p]["hits"]["wine-crash"]["count"], 1)
        self.assertNotIn("secretword", r.stdout)
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "signatures.py"), "list", "--json"],
                           capture_output=True, text=True)
        self.assertEqual(len(json.loads(r.stdout)), len(sg.CATALOG))


if __name__ == "__main__":
    unittest.main()
