# SPDX-License-Identifier: MIT
"""Unit tests for tools/report.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; the identity is made of pieces at run time (never this Mac's), except in the one test
of collect_identity, which checks its shape and prints nothing it learned."""
import builtins, importlib.util, json, os, pwd, re, subprocess, sys, tempfile, time, unittest, zipfile

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
REPO = os.path.dirname(os.path.abspath(TOOLS))
sys.dont_write_bytecode = True
sys.path.insert(0, TOOLS)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rp = load("report")
U = "/Us" + "ers/"                # never a literal home path in this file
AT = "@"
NOW = time.mktime((2026, 10, 16, 12, 0, 0, 0, 0, -1))


def win(p):
    return "Z:" + p.replace("/", "\\")


def base_facts(**kw):
    f = {"login": "design", "gecos": "Ana Lima", "home": U + "design", "data": U + "design/Work Files/revit-macos",
         "root": U + "design/Work Files/revit-macos", "hosts": ["Ana\u2019s MacBook", "Anas-Studio", "Anas-Studio.local"],
         "volumes": ["Work Disk"], "adsk_user": "alima42", "adsk_id": "QWERTY1234567890", "serial": "C02XK1ZZQ6L4",
         "hw_uuid": "4C4C4544-0042-3510-8051-B7C04F4E3732", "macs": ["a4:83:e7:0b:1c:2d"],
         "git_name": "Ana Lima", "git_email": "ana.lima" + AT + "example.org", "bottle": "client-x"}
    f.update(kw)
    return f


def slurp(path, mode="r"):
    with open(path, mode, **({} if "b" in mode else {"encoding": "utf-8"})) as f:
        return f.read()


def leftovers(text, values):
    """The values (by class, never printed) still in text, compared without case."""
    low = text.lower()
    return [cls for cls, v in values if v.lower() in low]


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, *parts):
        p = os.path.join(self.d, *parts)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    def write(self, rel, data):
        p = self.path(*rel.split("/"))
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        return p


class Redact(unittest.TestCase):
    def setUp(self):
        self.ident = rp.learn_identity(base_facts())

    def red(self, text):
        return rp.redact(text, self.ident)[0]

    def test_each_value_in_each_form(self):
        data = "Work Files/revit-macos"
        forms = {
            "posix": U + "design/Library/Logs/x and " + U + "design/" + data + "/logs/a",
            "tilde": "see ~/" + data + "/logs/rvt2027-a/x/rvt.log",
            "zusers": win(U + "design/Desktop") + " and " + win(U + "design/" + data) + "\\installers",
            "ydrive": "Y:\\" + data.replace("/", "\\") + "\\installers",
            "url": "file%3A%2F%2F%2FUsers%2Fdesign%2FLibrary and %2FUsers%2Fdesign%2F" + data.replace("/", "%2F"),
            "doubled": win(U + "design/Library").replace("\\", "\\\\"),
            "json": "\\/Users\\/design\\/Library",
            "nt": "L\"\\\\??\\\\Z:\\\\Users\\\\design\\\\Library\" and \\\\?\\Z:\\Users\\design\\x",
            "fileurl": "file://" + U + "design/Library/x.txt",
        }
        values = [("home", U + "design"), ("user", "design"), ("data", data)]
        for k, s in forms.items():
            out, counts = rp.redact(s, self.ident)
            self.assertEqual(leftovers(rp._normalize(out), [(c, rp._normalize(v)) for c, v in values]), [], k)
            self.assertTrue(counts, k)
            self.assertEqual(rp.gate(out, self.ident, k), [], k)

    def test_utf16_text_is_redacted(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.log")
            with open(p, "wb") as f:
                f.write(b"\xff\xfe" + ("on Anas-Studio: open " + win(U + "design/Library/a") + "\r\n").encode("utf-16-le"))
            text = "\n".join(rp._lines(p))
        out = self.red(text)
        self.assertEqual(leftovers(out, [("user", "design"), ("host", "anas-studio")]), [])
        self.assertIn("<HOST>", out)

    def test_login_design_common_word_and_exempt_contexts(self):
        s = ("Generative Design is on; design; DESIGN\n"
             "C:\\Program Files\\Autodesk\\Revit 2027\\AddIns\\Generative Design\\GD.dll\n"
             "Unpacking C:\\Windows\\Fonts\\Design Sans.ttf\n")
        out = self.red(s)
        lines = out.split("\n")
        self.assertEqual(lines[0], "Generative <USER> is on; <USER>; <USER>")
        self.assertIn("Generative Design\\GD.dll", lines[1])
        self.assertIn("Design Sans.ttf", lines[2])
        self.assertEqual(rp.gate(out, self.ident, "x"), [])
        self.assertTrue(rp.gate("made by Design", self.ident, "x"))

    def test_short_login_keeps_longer_words(self):
        ident = rp.learn_identity({"login": "ana", "home": U + "ana"})
        out = rp.redact("banana analysis ana Ana " + U + "ana/Library/x", ident)[0]
        self.assertEqual(out, "banana analysis <USER> <USER> ~/Library/x")
        self.assertEqual(rp.gate(out, ident, "x"), [])
        self.assertEqual(rp.gate("banana analysis", ident, "x"), [])
        self.assertTrue(rp.gate("by ana", ident, "x"))

    def test_login_under_three_characters_only_anchored(self):
        ident = rp.learn_identity({"login": "jo"})
        out = rp.redact("jo went " + U + "jo/Desktop and USER=jo", ident)[0]
        self.assertEqual(out, "jo went " + U + "<USER>/Desktop and USER=<USER>")

    def test_host_and_wine_form(self):
        ident = rp.learn_identity({"hosts": ["Anas-MacBook-Pro", "Anas-MacBook-Pro.local"]})
        out = rp.redact("ComputerName=ANAS-MACBOOK-PR; host Anas-MacBook-Pro.local; anas-macbook-pro", ident)[0]
        self.assertEqual(out, "ComputerName=<HOST>; host <HOST>.local; <HOST>")
        self.assertTrue(rp.gate("name ANAS-MACBOOK-PR", ident, "x"))
        stock = rp.learn_identity({"hosts": ["MacBook-Pro", "localhost"]})
        self.assertEqual(rp.redact("MacBook-Pro localhost", stock)[0], "MacBook-Pro localhost")

    def test_autodesk_user_that_is_a_common_word(self):
        ident = rp.learn_identity({"adsk_user": "model", "adsk_id": "QWERTY1234567890"})
        s = ("the model opened <MODEL-1>.rvt and C:\\x\\Generic Model.rfa\n"
             'Jrn.Directive  _\n        "Username"  , "model"\n'
             "C:\\users\\crossover\\AppData\\Roaming\\Autodesk\\ADPSDK\\UserConsent\\QWERTY1234567890.json")
        out = rp.redact(s, ident)[0]
        self.assertTrue(out.startswith("the <ADSK-USER> opened <MODEL-1>.rvt and C:\\x\\<MODEL-"), "tokens kept")
        self.assertIn('"Username"  , "<ADSK-USER>"', out)
        self.assertIn("UserConsent\\<ADSK-ID>.json", out)
        self.assertEqual(rp.gate(out, ident, "x"), [])

    def test_split_username_directive(self):
        ident = rp.learn_identity({})   # nothing learned: the anchored rule alone
        for s in ('Jrn.Directive "Username"  _\n        , "someone7"',
                  'Jrn.Directive  _\n        "Username"  , "someone7"',
                  'Jrn.Directive "Username" , "someone7"'):
            out = rp.redact(s, ident)[0]
            self.assertNotIn("someone7", out)
            self.assertTrue(rp.gate(s, None, "x"), s)
            self.assertEqual(rp.gate(out, None, "x"), [])

    def test_msi_property_dump(self):
        s = ("Property(S): ComputerName = ANAS-STUDIO\r\nProperty(S): USERNAME = Someone Else\r\n"
             "Property(S): LogonUser = crossover\r\nProperty(C): RegOwner = Big Client Ltd\r\n"
             "Property(S): ProductVersion = 27.3.0.28\r\n")
        out = rp.redact(s, rp.learn_identity({}))[0]
        self.assertIn("ComputerName = <HOST>", out)
        self.assertIn("USERNAME = <USER>\r\n", out)
        self.assertIn("LogonUser = crossover", out)
        self.assertIn("RegOwner = <NAME>", out)
        self.assertIn("ProductVersion = 27.3.0.28", out)

    def test_model_paths_with_spaces_and_parentheses(self):
        s = ("C:\\users\\crossover\\Documents\\Client Project (2026)\\Tower A (copy).rvt\n"
             "[C:\\users\\crossover\\Desktop\\Tower A (copy).rvt] opened\n"
             "Y:\\Projects\\Client Project (2026)\\Annex.rfa\n"
             "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\English\\Default-Multi-Discipline_Metric.rte\n"
             "~/Documents/Client Project (2026)/notes.txt\n")
        out = self.red(s).split("\n")
        self.assertEqual(out[0], "C:\\users\\crossover\\Documents\\<DIR-1>\\<MODEL-1>.rvt")
        self.assertEqual(out[1], "[C:\\users\\crossover\\Desktop\\<MODEL-1>.rvt] opened")
        self.assertEqual(out[2], "Y:\\<DIR-2>\\<DIR-1>\\<MODEL-2>.rfa")
        self.assertTrue(out[3].endswith("Default-Multi-Discipline_Metric.rte"))
        self.assertEqual(out[4], "~/Documents/<DIR-1>/<DIR-3>.txt")
        self.assertEqual(rp.gate("\n".join(out), self.ident, "x"), [])
        self.assertTrue(rp.gate("C:\\x\\Tower A (copy).rvt", None, "x"))
        self.assertTrue(rp.gate("C:\\users\\crossover\\Documents\\Client\\x.txt", None, "x"))

    def test_cyrillic_folder_and_model(self):
        s = "C:\\users\\crossover\\Documents\\\u041f\u0440\u043e\u0435\u043a\u0442\\\u0411\u0430\u0448\u043d\u044f.rvt"
        self.assertEqual(self.red(s), "C:\\users\\crossover\\Documents\\<DIR-1>\\<MODEL-1>.rvt")

    def test_secrets(self):
        jwt = "eyJhbGciOiJSUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0" + ".c2lnbmF0dXJlLXZhbHVl"
        s = ("token " + jwt + "\nAuthorization: Bearer abcdefghijklmnop0123\n"
             "adskidmgr://login?code=AbCdEf123456&state=xyz\n"
             "https://developer.api.autodesk.com/authentication/v2/authorize?client_id=ABC&code_challenge=x1#state=s\n"
             "refresh_token=QWERTYUIOP12345\n")
        for raw in s.strip().split("\n"):
            self.assertTrue(rp.gate(raw, None, "x"), raw[:12])
        out = self.red(s)
        for bit in ("eyJ", "abcdefghijklmnop", "AbCdEf", "client_id=ABC", "QWERTYUIOP"):
            self.assertNotIn(bit, out)
        self.assertIn("adskidmgr:<CALLBACK>", out)
        self.assertIn("authorize?client_id=<VALUE>&code_challenge=<VALUE>#state=<VALUE>", out)
        self.assertEqual(rp.gate(out, self.ident, "x"), [])

    def test_hardware_and_network(self):
        s = "serial C02XK1ZZQ6L4 uuid 4c4c4544-0042-3510-8051-b7c04f4e3732 en0 a4-83-e7-0b-1c-2d other 00:11:22:33:44:55"
        out = self.red(s)
        self.assertEqual(out, "serial <MAC-SERIAL> uuid <HW-UUID> en0 <MAC-ADDR> other <MAC-ADDR>")
        self.assertTrue(rp.gate("x 00:11:22:33:44:55", None, "x"))

    def test_emails_volumes_bottle_names(self):
        s = ("mail bob" + AT + "corp.test, git ana.lima" + AT + "example.org, noreply" + AT + "github.com\n"
             "/Volumes/Work Disk/projects/a.txt and /Volumes/Macintosh HD/x\nbottle client-x; Ana Lima\n")
        out = self.red(s)
        self.assertEqual(out, "mail <EMAIL>, git <EMAIL>, noreply" + AT + "github.com\n"
                              "/Volumes/<VOLUME-1>/projects/a.txt and /Volumes/<VOLUME-2>/x\nbottle <BOTTLE>; <NAME>\n")
        self.assertEqual(rp.gate(out, self.ident, "x"), [])

    def test_autodesk_serial(self):
        out = self.red("Serial number: 123-45678901; serial: 000-00000000; ADLM_PRODKEY 829R1")
        self.assertEqual(out, "Serial number: <SERIAL>; serial: 000-00000000; ADLM_PRODKEY 829R1")

    def test_must_stay_unchanged(self):
        s = ("000-00000000 829R1 C:\\users\\crossover\\AppData\\Local {8BC3F05E-D86B-11D0-A075-00C04FB68820}\n"
             "540731.357:04a8:02d8:trace:module:load_dll L\"C:\\\\windows\\\\system32\\\\ntdll.dll\" 4.0.0.0\n"
             "sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 C:\\users\\Public\\x\n"
             "C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe\n")
        self.assertEqual(self.red(s), s)
        self.assertEqual(rp.gate(s, self.ident, "x"), [])

    def test_second_run_changes_nothing(self):
        s = ("see " + U + "design/Work Files/revit-macos/logs/x.log on Anas-Studio as design; "
             "C:\\users\\crossover\\Documents\\Client\\Tower.rvt; /Volumes/Work Disk/a; eyJabcdefghij.eyJabcdefghij.abcd\n"
             'Jrn.Directive "Username" , "alima42"; mail bob' + AT + "corp.test; ~/Secret/x\n")
        once, _ = rp.redact(s, self.ident)
        twice, counts = rp.redact(once, self.ident)
        self.assertEqual(once, twice)
        self.assertEqual(counts, {})

    def test_run_folder_paths_become_relative(self):
        with tempfile.TemporaryDirectory() as d:
            run = os.path.join(os.path.realpath(d), "logs", "rvt2027-a", "20261014-145128-install")
            s = "licensing exit=1 failed; see %s/licensing.log\nZ:%s\\rvt.log" % (run, run.replace("/", "\\"))
            out = rp.redact(s, rp.learn_identity({"data": os.path.realpath(d)}), rel=run)[0]
        self.assertEqual(out, "licensing exit=1 failed; see licensing.log\nrvt.log")

    def test_denylist_words(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, ".report-denylist"), "w") as f:
                f.write("# client names\nFalconTower\n\n")
            words = rp._denylist(d, d)
        ident = rp.learn_identity({"denylist": words})
        self.assertEqual(rp.redact("the falcontower model", ident)[0], "the <PRIVATE> model")

    def test_identity_repr_shows_no_value(self):
        self.assertNotIn("design", repr(self.ident))
        self.assertNotIn("alima42", str(self.ident))


class Gate(unittest.TestCase):
    def test_planted_value_in_each_form(self):
        ident = rp.learn_identity(base_facts())
        data = "Work Files\\revit-macos"
        planted = {"posix": "x " + U + "design/a", "tilde": "~/Work Files/revit-macos/logs",
                   "zusers": "Z:\\Users\\design\\Desktop", "ydrive": "Y:\\" + data, "url": "%2FUsers%2Fdesign%2Fy",
                   "doubled": "Z:\\\\Users\\\\design\\\\x", "json": "\\/Users\\/design\\/z",
                   "word": "user design here", "host": "on ANAS-STUDIO", "adsk": "alima42 qwerty1234567890",
                   "serial": "c02xk1zzq6l4", "volume": "Work Disk", "email": "ana.lima" + AT + "example.org"}
        for k, s in planted.items():
            for data_ in (s, s.encode("utf-8"), s.encode("utf-16-le"), b"\xff\xfe" + s.encode("utf-16-le"),
                          b"x" + s.encode("utf-16-le")):
                hits = rp.gate(data_, ident, "f.txt")
                self.assertTrue(hits, "%s %r" % (k, type(data_)))
                for h in hits:
                    self.assertEqual(sorted(h), ["class", "file", "length", "line", "rule"])
                    self.assertTrue(isinstance(h["length"], int) and h["file"] == "f.txt")

    def test_hit_line_has_no_value(self):
        ident = rp.learn_identity({"login": "zorblax"})
        hits = rp.gate("one\ntwo zorblax\n", ident, "a.txt")
        self.assertEqual([rp.hit_line(h) for h in hits], ["learned\ta.txt\t2\tuser\t7"])


class Extracts(unittest.TestCase):
    def test_journal_allowlist(self):
        lines = [
            "' 0:< Initial VM: Avail 123 MB",
            "'C 12-Oct-2026 23:57:12.896;  started recording journal file",
            "' Build: 20260907_1515(x64)", "' Branch: RELEASE_2027.3", "' Release: 2027.3",
            "Dim Jrn", "Set Jrn = CrsJournalScript",
            "'C 12-Oct-2026 23:57:15.479;   0:< License initialization complete",
            "'C 12-Oct-2026 23:57:18.350;   0:< manage licensing - user mode",
            "' 0:< License mode: User", "' 0:< Status: Your license will expire in 334 days.",
            "' 0:< Expiration: Thursday, Sept 12, 2027",
            "'C 12-Oct-2026 23:57:20.058;   0:< Delayed start",
            "' 0:< Additional IP address/name found for host ANAS-STUDIO: 10.0.0.5 ANAS-STUDIO",
            "Jrn.Directive  _", '        "Version"  , "2027.000" , "2.179"',
            "Jrn.Directive  _", '        "Username"  , "alima42"',
            "Jrn.Directive  _", '        "AllowLinkSelection"  , 1',
            'Jrn.Command "Ribbon" , "Create a new project , ID_FILE_NEW_CHOOSE_TEMPLATE"',
            'Jrn.Command "Ribbon" , "Open Tower A from the client , Tower_A"',
            "Jrn.Data  _", '        "File Name"  , "IDOK" , "C:\\users\\crossover\\Documents\\Tower.rvt"',
            "Jrn.Activate \"[Tower.rvt]\" , \"Floor Plan: Level 1\"",
            "' 0:< API_SUCCESS { Registered an external server: Name(DB); VendorId(ADSK); ServerId(1) }",
            "' 0:< API_SUCCESS { Starting External Application: Name(Tool); VendorId(ACME) }",
            "' 0:< API_ERROR { Failed to load: Name(Bad); VendorId(ACME) }",
            "  ' 0:< TaskDialog \"Do you want to save Tower A?\"", "  'CommonButtons : Yes, No, Cancel",
            "  'DefaultButton : Yes", "  'Id : TaskDialog_Save_Changes",
            "    Jrn.Data  _", '            "TaskDialogResult"  , "Do you want to save Tower A?" ,  _',
            '             "No"  _', '            , "IDNO"',
            "    ' [Jrn.AutoConvertedMessageBox] Rvt.Attr.MessageId: String_X Rvt.Attr.MessageAnswer: IDNO",
            "'C 12-Oct-2026 23:59:05.023;   0:< Exception occurred in OGS",
            "'C 12-Oct-2026 23:59:06.000;   0:< Error opening \"Tower A\" [Tower A - Level 1] 'Annex'",
            "' 0:< This: [\"Tower A\"] - Floor Plan: Level 1", "' 0:< GlobalToProj 1 0 0",
            'Jrn.Command "Internal" , "Exit the application , ID_APP_EXIT"',
            "'C 12-Oct-2026 23:59:09.000;   0:< finished recording journal file",
        ]
        out = rp.journal_extract(lines)
        text = "\n".join(out)
        for keep in ("' Build: 20260907_1515(x64)", "' Release: 2027.3", "0:< License initialization complete",
                     "0:< manage licensing - user mode", "0:< License mode: User", "0:< license expiry: ok",
                     "Delayed start", 'Jrn.Directive "Version" , "2027.000" , "2.179"',
                     'Jrn.Command "Ribbon" ID_FILE_NEW_CHOOSE_TEMPLATE', 'Jrn.Command "Ribbon" (id not kept)',
                     "0:< TaskDialog (text dropped)", "'Id : TaskDialog_Save_Changes", "'CommonButtons : Yes, No, Cancel",
                     'Jrn.Data "TaskDialogResult" IDNO', "MessageId: String_X MessageAnswer: IDNO",
                     "Exception occurred in OGS", 'Jrn.Command "Internal" ID_APP_EXIT',
                     "0:< Error opening \"\u2026\" [\u2026] '\u2026'",
                     "finished recording journal file", "started recording journal file",
                     "add-in lines: 3 (1 errors); Autodesk vendor ids: ADSK"):
            self.assertIn(keep, text)
        for gone in ("alima42", "Expiration", "Tower", "ANAS", "10.0.0.5", "Branch", "AllowLinkSelection", "ACME",
                     "Level 1", "334", "Annex"):
            self.assertNotIn(gone, text)
        self.assertTrue(any(re.match(r"^\u2026 \d+ lines dropped$", s) for s in out))
        self.assertIn("0:< license expiry: 7 days or less",
                      rp.journal_extract(["' 0:< Status: Your license will expire in 5 days."]))

    def msi_log(self):
        lines = ["=== Verbose logging started: 10/14/2026  15:08:19 ==="]
        lines += ["Property(S): ComputerName = ANAS-STUDIO", "Property(S): USERNAME = Ana Lima",
                  "Property(S): SourceDir = " + win(U + "design/x") + "\\"]
        for w in range(12):
            lines += ["Action start 15:08:%02d: Step%d." % (w, j) for j in range(50)]
            lines += ["MSI (s) (A4:B8) [15:08:20:123]: Product: Autodesk -- Error 1722. There is a problem."]
            lines += ["CustomAction CA%d returned actual error code 1603" % w, "Action ended 15:08:20: CA%d. Return value 3." % w]
        lines += ["Action ended 15:09:00: INSTALL. Return value 1.", "after the last failure: not a tail"]
        lines += ["Property(S): ProductVersion = 27.3.0.28", "Property(S): ProductCode = {11111111-2222-3333-4444-555555555555}",
                  "Property(S): ADLM_PRODKEY = 829S1", "Property(C): LogonUser = crossover"]
        return lines

    def test_msi_windows_and_properties(self):
        out = rp.msi_extract(self.msi_log())
        text = "\n".join(out)
        self.assertEqual(text.count('lines before "Return value 3"'), 10)
        self.assertIn("Error 1722", text)
        self.assertIn("returned actual error code 1603", text)
        self.assertIn("Property(S): ProductVersion = 27.3.0.28", text)
        self.assertIn("Property(S): ADLM_PRODKEY = 829S1", text)
        for gone in ("ComputerName", "USERNAME", "SourceDir", "LogonUser", "not a tail", "Step0."):
            self.assertNotIn(gone, text)
        self.assertLessEqual(max(len(re.findall(r"Action start", text)), 0), 10 * 40)
        self.assertEqual(rp.msi_extract(["Action ended 1: X. Return value 1.", "Property(S): ProductVersion = 1"]), [])

    def cx_header(self, when):
        return ["***** %s" % when,
                "Starting: '/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine' '--bottle' 'client-x' "
                "'C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe' 'C:\\users\\crossover\\Documents\\Tower.rvt'", "",
                "2147: Grabbing the '/var/folders/q1/abcdefgh/T//.wine-501/bottle-0-0.lock' lock",
                "CXConfig->read(" + U + "design/Library/Application Support/CrossOver/Bottles/client-x/cxbottle.conf)",
                "Product version=26.3.0.39832", "Mode = 'private'", "Environment:",
                '  CX_BOTTLE = "client-x"', '  WINEPREFIX = "' + U + 'design/Library/Application Support/x"',
                '  PATH = "/Applications/CrossOver.app/bin:' + U + 'design/.local/bin:/Volumes/Work Disk/bin:/usr/bin"',
                '  CX_DEBUGMSG = "err,+seh"', '  WINEDEBUG = "err,+seh"', "Command:",
                "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader x", ""]

    def test_cxlog_header_fields_and_tail(self):
        lines = self.cx_header("Wed Oct 14 15:08:19 2026")
        lines += ["540731.357:04a8:02d8:trace:module:load %d" % i for i in range(300)]
        lines += self.cx_header("Wed Oct 14 16:00:00 2026")
        lines += ["0024:err:module:import_dll Library not found %d" % i for i in range(20)]
        out = rp.cxlog_extract(lines)
        text = "\n".join(out)
        for gone in ("Environment", "CXConfig", "Starting", "Command:", "WINEPREFIX", "/Volumes", "Tower", "client-x",
                     "Grabbing", "/usr/bin"):
            self.assertNotIn(gone, text)
        for keep in ("2 sessions", "Product version: 26.3.0.39832", "Mode: private", "PATH: 4 entries",
                     "CX_DEBUGMSG: err,+seh", "backend: default", "Library not found 19", "load 299"):
            self.assertIn(keep, text)
        self.assertNotIn("load 120", text)
        self.assertTrue(any("header lines left out" in s for s in out))
        self.assertLessEqual(len([s for s in out if s.startswith(("5407", "0024"))]), rp.TAIL)


class Build(Tmp):
    """A data folder with an install, a debug session and a test run, a bottle with a non-default name, Revit.ini and a
    journal; the identity comes from learn_identity over these fixtures."""

    def setUp(self):
        super().setUp()
        self.home, self.bottles = self.path("home"), self.path("Bottles")
        self.data = self.path("home", "Work Files", "revit-macos")   # a clone in the home, as most are
        os.makedirs(self.data)
        self.bottle = "client-x"
        bdir = os.path.join(self.bottles, self.bottle)
        jdir = "Bottles/client-x/drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit 2027/Journals"
        ini = ("[Graphics]\r\nAntialiasing=0\r\n[Language]\r\nSelect=ENU\r\n[Partitions]\r\nUsername=alima42\r\n"
               "UserId=QWERTY1234567890\r\n[Recent File List]\r\nFile1=C:\\users\\crossover\\Documents\\Tower.rvt\r\n")
        self.write("Bottles/client-x/drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit 2027/Revit.ini",
                   b"\xff\xfe" + ini.encode("utf-16-le"))
        self.write(jdir + "/journal.0003.txt", "' Build: 20260907_1515(x64)\n' Release: 2027.3\n"
                   "Jrn.Directive  _\n        \"Username\"  , \"alima42\"\n"
                   "'C 14-Oct-2026 15:00:00.000;   0:< License mode: User\n")
        self.write("Bottles/client-x/revit-macos/runs.ndjson",
                   json.dumps({"run_id": "r1", "time": "2026-10-14T13:51:28Z", "kind": "install", "year": 2027,
                               "result": "partial", "failed": ["licensing"]}) + "\n")
        self.facts = base_facts(home=self.home, data=self.data, root=REPO, bottle=self.bottle)
        self.facts.update({k: v for k, v in rp.bottle_facts(bdir, "2027").items()})
        self.ident = rp.learn_identity(self.facts)
        inst = "home/Work Files/revit-macos/logs/client-x/20261014-145128-install"
        run = os.path.join(self.data, "logs", "client-x", "20261014-145128-install")
        self.write(inst + "/summary.txt",
                   "   bottle     exit=0     scripts/new-bottle.sh 2027 client-x (23 s; action-bottle.log)\n"
                   "   licensing  exit=1     AdskLicensing-installer.exe; see ~%s/licensing.log (56 s)\n"
                   "   RVTCPSTLCON exit=0     %s\\installers\\extracted\\revit2027\\x64\\R.msi (1 s)\n"
                   "   steps      exit=1     scripts/run-steps.sh 2027 client-x (282 s; action-steps.log)\n"
                   % (run[len(self.home):] if run.startswith(self.home) else run, win(self.data)))
        self.write(inst + "/failed.txt", "licensing\n../../etc/passwd\n")
        self.write(inst + "/licensing.log", "installing for design on Anas-Studio\n%s\\x\n/Volumes/Work Disk/a\n"
                   % win(self.home + "/Desktop"))
        self.write(inst + "/action-steps.log", "steps failed\n")
        msi = ["Property(S): ComputerName = ANAS-STUDIO", "Action start 1: A.", "MSI (s): Error 1722. problem",
               "Action ended 1: A. Return value 3.", "Property(S): ProductVersion = 27.3.0.28"]
        self.write(inst + "/rvt.msi.log", "\r\n".join(msi) + "\r\n")
        self.write(inst + "/ok.msi.log", "Action ended 1: A. Return value 1.\r\n")
        self.forbidden = ["d3d9-dxvk-native.dll", "version_orig.dll", "setup.exe", "RVT.msi", "Tower.rvt",
                          "user.reg", "wine.cxlog", "LoginState.xml", "Cookies", "Local State", "journal.0001.txt",
                          ".DS_Store", "AdSSO.dmp", "adlm.dat"]
        for f in self.forbidden:
            self.write(inst + "/" + f, b"MZ\x00\x00 design " + bytes(64))
        dbg = "home/Work Files/revit-macos/logs/client-x/20261001-101010-debug"
        cx = Extracts().cx_header("Thu Oct  1 10:10:10 2026") + ["0024:err:x %d on Anas-Studio" % i for i in range(250)]
        self.write(dbg + "/wine.cxlog", "\n".join(cx) + "\n")
        self.write(dbg + "/stdout.log", "started\n")
        self.write(dbg + "/pid", "123\n")
        self.write("home/Work Files/revit-macos/logs/client-x/20261015-090000-test/result.json",
                   json.dumps({"verdict": "pass", "bottle": "client-x", "dialog_id": None}))
        self.out = os.path.join(self.data, "logs", "client-x", "20261016-120000-report")

    def build(self, out=None, **kw):
        args = dict(year="2027", bottle=self.bottle, identity=self.ident, now=NOW)
        args.update(kw)
        return rp.build(REPO, self.data, self.bottles, out or self.out, **args)

    def zip_members(self, path):
        with zipfile.ZipFile(path) as z:
            return {n: z.read(n) for n in z.namelist()}

    def values(self):
        return [("home", self.home), ("user", "design"), ("adsk_user", "alima42"), ("adsk_id", "qwerty1234567890"),
                ("host", "anas-studio"), ("bottle", "client-x"), ("volume", "work disk"), ("model", "tower")]

    def test_report_and_zip(self):
        r = self.build()
        self.assertIsNone(r["refused"])
        rt = slurp(r["report_txt"])
        members = self.zip_members(r["report_zip"])
        names = sorted(members)
        for n in ("install/summary.txt", "install/failed.txt", "install/licensing.log", "install/action-steps.log",
                  "install/rvt-errors.txt", "debug/wine-cxlog.txt", "debug/stdout.log", "test/result.json",
                  "bottle/runs.ndjson", "bottle/revit-ini.txt", "bottle/journal-extract.txt", "manifest.txt"):
            self.assertIn(n, names)
        for n in names:
            self.assertIsNone(rp.REFUSE_RX.search(n), n)
        everything = rt + "\n".join(n + "\n" + b.decode("utf-8") for n, b in members.items())
        self.assertEqual(leftovers(everything, self.values()), [])
        self.assertEqual(rp.gate(rt, self.ident, "report.txt"), [])
        for n, b in members.items():
            self.assertEqual(rp.gate(b, self.ident, n), [], n)
        summary = members["install/summary.txt"].decode()
        self.assertIn("see licensing.log", summary)
        self.assertIn("<DATA>\\installers\\extracted", summary)
        manifest = members["manifest.txt"].decode()
        for f in self.forbidden:
            shown = "<MODEL-1>.rvt" if f == "Tower.rvt" else f
            self.assertTrue(re.search(r"20261014-145128-install/%s \u2014 " % re.escape(shown), manifest), f)
        self.assertIn("ok.msi.log \u2014 an MSI log without a failure", manifest)
        self.assertFalse([n for n in names if ".." in n or "passwd" in n], "a member from outside the run folder")
        ini = members["bottle/revit-ini.txt"].decode()
        self.assertEqual(ini, "[Graphics] Antialiasing=0\n[Language] Select=ENU")
        self.assertIn("Revit: 2027, bottle <BOTTLE>", rt)
        self.assertIn("Last install (2026-10-14): partial; failed steps: licensing", rt)
        self.assertIn("debug session: 15 days old; if the problem is new, run ./revit debug 2027 <BOTTLE> first", rt)
        self.assertIn("install log: 1 day old", rt)
        self.assertIn("Revit build (newest journal): 20260907_1515(x64), release 2027.3", rt)
        self.assertRegex(rt, r"Replaced: your user name \d+\u00d7")
        self.assertIn("Not included: ", rt)
        self.assertLessEqual(len(rt.encode()), rp.REPORT_MAX)
        self.assertEqual(r["left_out"], [])

    def test_forbidden_files_are_never_opened(self):
        opened, real = [], builtins.open

        def spy(file, *a, **k):
            opened.append(str(file))
            return real(file, *a, **k)
        builtins.open = spy
        try:
            self.build()
        finally:
            builtins.open = real
        inst = os.path.join(self.data, "logs", "client-x", "20261014-145128-install")
        for f in self.forbidden:
            self.assertNotIn(os.path.join(inst, f), opened)
        for p in opened:
            self.assertIsNone(rp.NEVER_OPEN_RX.search(p), p)

    def test_second_run_changes_nothing(self):
        a = self.build(self.path("out1"))
        b = self.build(self.path("out2"))
        self.assertEqual(slurp(a["report_txt"], "rb"), slurp(b["report_txt"], "rb"))
        self.assertEqual(self.zip_members(a["report_zip"]), self.zip_members(b["report_zip"]))
        self.assertEqual(slurp(a["report_zip"], "rb"), slurp(b["report_zip"], "rb"))

    def test_only_the_out_dir_is_written(self):
        before = sorted(os.path.join(r, n) for r, ds, fs in os.walk(self.d) for n in ds + fs)
        r = self.build()
        after = sorted(os.path.join(r_, n) for r_, ds, fs in os.walk(self.d) for n in ds + fs)
        new = [p for p in after if p not in before]
        self.assertEqual(sorted(new), sorted([self.out, r["report_txt"], r["report_zip"]]))

    def test_member_with_a_leak_is_left_out(self):
        with open(os.path.join(self.data, "logs/client-x/20261014-145128-install/licensing.log"), "a") as f:
            f.write("copied from %sbob/Desktop\n" % U)
        r = self.build()
        self.assertIsNone(r["refused"])
        members = self.zip_members(r["report_zip"])
        self.assertNotIn("install/licensing.log", members)
        self.assertEqual([x["member"] for x in r["left_out"]], ["install/licensing.log"])
        self.assertTrue(all(h["rule"] == "users-path" for h in r["left_out"][0]["hits"]))
        rt = slurp(r["report_txt"])
        self.assertIn("Left out: tail of licensing.log \u2014 it holds personal data that could not be removed.", rt)
        self.assertIn("install/licensing.log \u2014 tail of licensing.log: it holds personal data", members["manifest.txt"].decode())
        self.assertNotIn("bob", rt + members["manifest.txt"].decode())

    def test_leak_in_report_txt_means_no_report(self):
        doc = self.path("doctor.json")
        with open(doc, "w") as f:
            json.dump({"checks": [{"id": "bottle.docs", "status": "warn", "title": "Documents points at %sbob/Docs" % U,
                                   "fix": "relink it"}], "summary": {}}, f)
        r = self.build(doctor_json=doc)
        self.assertEqual(r["refused"], "report.txt holds personal data that could not be removed")
        self.assertIsNone(r["report_txt"])
        self.assertFalse(os.path.exists(self.out))
        self.assertTrue(r["hits"])
        self.assertNotIn("bob", json.dumps(r))

    def test_doctor_problems_in_report(self):
        doc = self.path("doctor.json")
        with open(doc, "w") as f:
            json.dump({"checks": [{"id": "host.rosetta", "status": "fail", "title": "Rosetta 2 is not installed",
                                   "fix": "softwareupdate --install-rosetta"},
                                  {"id": "host.arm", "status": "ok", "title": "Apple Silicon"}]}, f)
        r = self.build(doctor_json=doc)
        rt = slurp(r["report_txt"])
        self.assertIn("./revit doctor: 1 problem\n  \u2717 host.rosetta: Rosetta 2 is not installed\n"
                      "      fix: softwareupdate --install-rosetta", rt)
        self.assertIn("doctor.json", self.zip_members(r["report_zip"]))

    def test_exclude(self):
        r = self.build(exclude=["licensing.log"])
        self.assertNotIn("install/licensing.log", self.zip_members(r["report_zip"]))
        self.assertIn("left out on request", self.zip_members(r["report_zip"])["manifest.txt"].decode())

    def test_size_caps(self):
        inst = os.path.join(self.data, "logs/client-x/20261014-145128-install")
        with open(os.path.join(inst, "licensing.log"), "w") as f:
            for i in range(4000):
                f.write("line %d %s\n" % (i, "x" * 3000))
        doc = self.path("doctor.json")
        with open(doc, "w") as f:
            json.dump({"checks": [{"id": "c%d" % i, "status": "warn", "title": "t" * 250, "fix": "f" * 250}
                                  for i in range(200)]}, f)
        r = self.build(doctor_json=doc)
        members = self.zip_members(r["report_zip"])
        for n, b in members.items():
            self.assertLessEqual(len(b), rp.MEMBER_MAX + 64, n)
            self.assertLessEqual(max(len(x) for x in b.decode().split("\n")), rp.LINE_MAX, n)
        self.assertLessEqual(os.path.getsize(r["report_txt"]), rp.REPORT_MAX)
        self.assertLessEqual(os.path.getsize(r["report_zip"]), rp.ZIP_MAX)

    def test_zip_over_the_limit_drops_members(self):
        old = rp.ZIP_MAX
        rp.ZIP_MAX = 1500
        try:
            r = self.build()
        finally:
            rp.ZIP_MAX = old
        self.assertLessEqual(os.path.getsize(r["report_zip"]), 1500)
        self.assertTrue(any(x["reason"] == "the report would be over 5 MB" for x in r["left_out"]))

    def test_binary_member_is_left_out(self):
        with open(os.path.join(self.data, "logs/client-x/20261001-101010-debug/stdout.log"), "wb") as f:
            f.write(b"\x00" * 3000 + b"\nend\n")
        r = self.build()
        self.assertIn({"member": "debug/stdout.log", "what": "tail of stdout.log", "reason": "it is not a text file",
                       "hits": []}, r["left_out"])

    def test_run_context(self):
        ctx = self.path("home", "Work Files", "revit-macos", "logs", "runs", "20261014-145128-999")
        os.makedirs(ctx)
        run = os.path.join(self.data, "logs", "client-x", "20261014-145128-install")
        with open(os.path.join(ctx, "result"), "w") as f:
            f.write("result=partial\nfailed_steps=licensing\nlog_dir=%s\n" % run)
        with open(os.path.join(ctx, "events.ndjson"), "w") as f:
            f.write('{"event":"start","command":"install"}\n')
        r = self.build(run=ctx)
        members = self.zip_members(r["report_zip"])
        self.assertIn("run/result.txt", members)
        self.assertIn("log_dir=<DATA>/logs/<BOTTLE>/20261014-145128-install", members["run/result.txt"].decode())
        self.assertIn("install/summary.txt", members)
        self.assertNotIn("debug/wine-cxlog.txt", members)

    def test_run_folder_outside_the_logs_is_not_read(self):
        ctx = self.path("events", "r1")
        os.makedirs(ctx)
        self.write("elsewhere/summary.txt", "   rvt        exit=0     secret summary\n")
        with open(os.path.join(ctx, "result"), "w") as f:
            f.write("result=ok\nlog_dir=%s\n" % self.path("elsewhere"))
        r = self.build(run=ctx)
        members = self.zip_members(r["report_zip"])
        self.assertEqual(sorted(n.split("/")[0] for n in members if "/" in n), ["bottle"] * 3 + ["run"])
        self.assertNotIn("secret summary", "".join(b.decode() for b in members.values()))

    def test_no_bottle_no_year(self):
        r = rp.build(REPO, self.data, os.path.join(self.d, "none"), self.path("o"), identity=self.ident, now=NOW)
        rt = slurp(r["report_txt"])
        self.assertIn("Revit: no year given", rt)
        self.assertIn("install/summary.txt", self.zip_members(r["report_zip"]))


class Machine(Tmp):
    def test_collect_identity_shape(self):
        ident = rp.collect_identity(REPO, self.d)   # this Mac: only its shape is checked, nothing is printed
        self.assertTrue(isinstance(ident, rp.Identity), "not an Identity")
        login = pwd.getpwuid(os.getuid()).pw_name
        self.assertTrue(login not in repr(ident) and login not in str(ident), "repr shows a value")
        self.assertTrue(ident.login == login, "login not learned")
        self.assertTrue(all(isinstance(p, str) and p.startswith("/") and c in rp.LABELS for c, p in ident.paths),
                        "path shape")
        self.assertTrue(all(isinstance(v, str) and v and c in rp.LABELS for c, v in ident.words), "word shape")
        self.assertTrue(all(len(x) == 3 for x in ident.gate_values()), "gate values shape")
        facts = rp.machine_facts(REPO, self.d)
        for k in ("login", "gecos", "home", "data", "root", "hosts", "volumes", "serial", "hw_uuid", "macs",
                  "denylist"):
            self.assertTrue(k in facts, "fact missing: " + k)
        self.assertTrue(all(re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", m) for m in facts["macs"]), "mac shape")


class Cli(Tmp):
    def run_tool(self, *args):
        env = {k: v for k, v in os.environ.items() if k not in ("REVIT_DATA", "REVIT_CX")}
        env["HOME"] = self.path("home")
        os.makedirs(env["HOME"], exist_ok=True)
        return subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "report.py")] + list(args),
                              capture_output=True, text=True, env=env, cwd="/")

    def test_gate_prints_rule_file_line_class_length_never_the_value(self):
        p = self.write("x.txt", "fine\nfrom %sbobbins/Desktop\n" % U)
        r = self.run_tool("gate", p)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.strip().split("\n"), ["users-path\tx.txt\t2\tpath\t14"])
        self.assertNotIn("bobbins", r.stdout + r.stderr)
        z = self.path("r.zip")
        with zipfile.ZipFile(z, "w") as f:
            f.writestr("a.txt", "token eyJabcdefghij.eyJabcdefghij.abcdefgh\n")
        r = self.run_tool("gate", z, self.write("ok.txt", "nothing here\n"))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.strip(), "jwt\tr.zip:a.txt\t1\ttoken\t36")
        self.assertEqual(self.run_tool("gate", self.write("ok2.txt", "nothing\n")).returncode, 0)

    def test_build_json(self):
        data = self.path("data")
        self.write("data/logs/rvt2027-a/20261014-145128-install/summary.txt", "   rvt        exit=0     RVT.msi (8 s)\n")
        out = self.path("data", "logs", "rvt2027-a", "20261016-120000-report")
        r = self.run_tool("build", "--root", REPO, "--data", data, "--bottles", self.path("none"), "--year", "2027",
                          "--bottle", "rvt2027-a", "--out-dir", out, "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        j = json.loads(r.stdout)
        self.assertEqual(sorted(j), ["hits", "left_out", "refused", "report_txt", "report_zip", "summary"])
        self.assertEqual(j["report_txt"], os.path.join(out, "report.txt"))
        self.assertTrue(os.path.isfile(j["report_zip"]))
        r = self.run_tool("build", "--root", REPO, "--data", data, "--out-dir", self.path("o2"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Report: ", r.stdout)
        self.assertEqual(self.run_tool("build", "--year", "27", "--out-dir", self.path("o3")).returncode, 2)
        self.assertEqual(self.run_tool("build").returncode, 2)

    def test_no_bytecode_written(self):
        before = set(os.listdir(TOOLS))
        self.run_tool("gate", self.write("ok.txt", "x\n"))
        self.assertEqual(set(os.listdir(TOOLS)), before)


if __name__ == "__main__":
    unittest.main()
