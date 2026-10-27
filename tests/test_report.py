# SPDX-License-Identifier: MIT
"""Unit tests for tools/report.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; the identity is made of pieces at run time (never this Mac's), except in the one test
of collect_identity, which checks its shape and prints nothing it learned."""
import builtins, importlib.util, json, os, pwd, re, subprocess, sys, tempfile, time, unicodedata, unittest, zipfile

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
        s = ("mail bob" + AT + "corp.test, git ana.lima" + AT + "example.org, docs x" + AT + "example.net\n"
             "/Volumes/Work Disk/projects/a.txt and /Volumes/Macintosh HD/x\nbottle client-x; Ana Lima\n")
        out = self.red(s)
        self.assertEqual(out, "mail <EMAIL>, git <EMAIL>, docs x" + AT + "example.net\n"
                              "/Volumes/<VOLUME-1>/projects/a.txt and /Volumes/<VOLUME-2>/x\nbottle <BOTTLE>; <NAME>\n")
        self.assertEqual(rp.gate(out, self.ident, "x"), [])

    def test_email_exempt_only_at_the_documentation_domains(self):
        ident = rp.learn_identity({})
        replaced = ["noreply" + AT + "github.com", "no-reply" + AT + "corp.test",
                    "12345+someone" + AT + "users.noreply.github.com", "x" + AT + "example.com.evil.test",
                    "x" + AT + "sub.example.org", "x" + AT + "example.community", "j\u00f6rg" + AT + "corp.test"]
        for a in replaced:
            out = rp.redact("from " + a + ".", ident)[0]
            self.assertEqual(out, "from <EMAIL>.", a[:6])
            self.assertTrue(rp.gate("from " + a, None, "x"), a[:6])
            self.assertEqual(rp.gate(out, None, "x"), [], a[:6])
        kept = ["x" + AT + "example.com", "first.last" + AT + "example.org", "a_b+c" + AT + "example.net",
                "email=x" + AT + "example.com", "'x" + AT + "example.org'"]
        for a in kept:
            self.assertEqual(rp.redact(a, ident)[0], a, a[:6])
            self.assertEqual(rp.gate(a, None, "x"), [], a[:6])

    def test_gate_email_is_stricter_than_the_redaction(self):
        for a in ("bob!x" + AT + "corp.test", "b\u00f6b" + AT + "corp.test", "%62ob" + AT + "corp.test",
                  "bob%40corp.test", "b\\u00f6b" + AT + "corp.test"):
            self.assertTrue([h for h in rp.gate(a, None, "x") if h["rule"] == "email"], a[:4])

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
             'Jrn.Directive "Username" , "alima42"; mail bob' + AT + "corp.test; ~/Secret/x\n"
             "connect to 10.0.0.5:443 and host 2001:db8::1\n")
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


class UnicodeForms(unittest.TestCase):
    """Learned values and text in NFC or NFD and in any case: the redaction and the gate see one form."""

    def nfd(self, s):
        return unicodedata.normalize("NFD", s)

    def test_nfd_text_and_nfc_values(self):
        login, name = "jos\u00e9", "Jos\u00e9 Mu\u00f1oz"
        ident = rp.learn_identity({"login": login, "gecos": name, "home": U + login})
        text = "by %s (%s) at %s/Library/x" % (self.nfd(login), self.nfd(name), U + self.nfd(login))
        self.assertNotEqual(text, unicodedata.normalize("NFC", text))
        out = rp.redact(text, ident)[0]
        self.assertEqual(out, "by <USER> (<NAME>) at ~/Library/x")
        self.assertEqual(rp.gate(out, ident, "x"), [])
        hits = rp.gate(text, ident, "x")   # planted past the redaction, in NFD: caught
        self.assertEqual(sorted({h["class"] for h in hits if h["rule"] == "learned"}), ["home", "name", "user"])
        for data in (text.encode("utf-8"), text.encode("utf-16-le"), json.dumps(text).encode("ascii")):
            self.assertTrue([h for h in rp.gate(data, ident, "x") if h["rule"] == "learned"], data[:6])

    def test_nfd_values_and_nfc_text(self):
        ident = rp.learn_identity({"login": self.nfd("jos\u00e9"), "adsk_user": self.nfd("Ren\u00e9e")})
        self.assertEqual(rp.redact("jos\u00e9 and REN\u00c9E", ident)[0], "<USER> and <ADSK-USER>")
        self.assertTrue(rp.gate("by ren\u00e9e", ident, "x"))
        self.assertEqual(rp.redact("jose", ident)[0], "jose")   # without the accent: another word
        self.assertEqual(rp.gate("jose", ident, "x"), [])

    def test_case_that_changes_length(self):
        ident = rp.learn_identity({"gecos": "Stra\u00dfe Lima"})
        self.assertEqual(rp.redact("STRASSE, strasse and Stra\u00dfe", ident)[0], "<NAME>, <NAME> and <NAME>")
        self.assertTrue(rp.gate("by STRASSE", ident, "x"))
        self.assertTrue(rp.gate("by stra\u00dfe", ident, "x"))

    def test_percent_escapes_are_decoded_in_full(self):
        ident = rp.learn_identity({"login": "jos\u00e9", "home": U + "jos\u00e9"})
        for s in ("file://" + U + "jos%C3%A9/x", "by jos%25C3%25A9", "%2FUsers%2Fjos%C3%A9", "jos%c3%a9%0Aon"):
            self.assertTrue([h for h in rp.gate(s, ident, "x") if h["rule"] == "learned"], s[:8])
        self.assertEqual([h["line"] for h in rp.gate("one\ntwo jos%C3%A9%0A\nthree", ident, "x")], [2])


class Network(unittest.TestCase):
    def test_ip_addresses_in_a_network_context_are_replaced(self):
        cases = [
            ("' 0:< Additional IP address/name found for host <HOST>: 10.20.30.40 <HOST>",
             "' 0:< Additional IP address/name found for host <HOST>: <IP-1> <HOST>"),
            ("connect to 192.168.1.20:443 failed", "connect to <IP-1>:443 failed"),
            ("GET http://10.1.2.3/path?x=1", "GET http://<IP-1>/path?x=<VALUE>"),
            ("copy \\\\172.16.0.9\\share", "copy \\\\<IP-1>\\share"),
            ("ssh admin" + AT + "172.16.0.4", "ssh admin" + AT + "<IP-1>"),
            ("url http://[fe80::1c2:3ff:fe4a:5b6c]:8080/x", "url http://[<IP-1>]:8080/x"),
            ("socket bound to 2001:db8::8a2e:370:7334.", "socket bound to <IP-1>."),
            ("server 10.0.0.5, again 10.0.0.5 and 10.0.0.6", "server <IP-1>, again <IP-1> and <IP-2>"),
            ("proxy ::ffff:10.0.0.5 up", "proxy <IP-1> up"),
            ('{"u": "http:\\/\\/10.0.0.5\\/x"}', '{"u": "http:\\/\\/<IP-1>\\/x"}'),
            ('L"\\\\\\\\10.0.0.5\\\\share" open', 'L"\\\\\\\\<IP-1>\\\\share" open'),
        ]
        for raw, want in cases:
            out, counts = rp.redact(raw, rp.learn_identity({}))
            self.assertEqual(out, want)
            self.assertTrue(counts.get("ip"), raw[:12])
            self.assertTrue([h for h in rp.gate(raw, None, "x") if h["rule"] == "ip-address"], raw[:12])
            self.assertEqual(rp.gate(out, None, "x"), [], raw[:12])
            self.assertEqual(rp.redact(out, rp.learn_identity({}))[0], out)

    def test_versions_loopback_and_wine_lines_stay(self):
        for s in ("Product version=26.3.0.39832", "Revit 27.3.0.28 build", "Property(S): ProductVersion = 27.3.0.28",
                  "CrossOver 24.3.60.12", "server version 24.3.60.12", "UA CrossOver/24.3.60.12 (http)",
                  "host 127.0.0.1, ::1 and 0.0.0.0 here", "localhost 127.0.0.1:8080", "connect 127.0.1.1",
                  "540731.357:04a8:02d8:trace:module:load_dll host", "[15:08:20:123] connect", "01.02.03.04 host",
                  "address 1.2.3.4.5", "http 999.1.1.1", "ADocumentUpgrade::docUpgrade url", "socket 26.3.0.39832",
                  'trace:module:load L"C:\\\\Program Files\\\\Autodesk\\\\AdskLicensing\\\\15.0.0.12\\\\x.exe" host',
                  "Rvt.Attr.AddInVersion: 1.2.3.4 Rvt.Attr.VendorDescription: https://www.autodesk.com",
                  "VersionBuild: 24.2.10.64 host", "C:\\Program Files\\Autodesk\\Manager\\4.1.2.3\\x connect"):
            self.assertEqual(rp.redact(s, rp.learn_identity({}))[0], s, s)
            self.assertEqual(rp.gate(s, None, "x"), [], s)
        self.assertEqual(rp._summary({}, self.numbered(3)), "Replaced: 3 IP addresses")

    def numbered(self, n):
        ident = rp.learn_identity({})
        for i in range(n):
            ident.number("ip", "10.0.0.%d" % i)
        return ident


class GateRev3(unittest.TestCase):
    def test_users_and_volumes_exemptions_are_whole_segments(self):
        hits = [U + "PublicAlice/Desktop/notes.txt", U + "shared-x/y", U + "Public.bob/y", U + "Public Alice/Desktop",
                U + "Shared folder/x", U + "<USER>x/Desktop", U + "crossovers/x", "/Volumes/<VOLUME-1>x/y",
                "/Volumes/Work Disk/x", "C:\\Users\\PublicAlice\\x", "%2FUsers%2FPublicAlice%2Fx", "%252FUsers%252Fbob"]
        for s in hits:
            self.assertTrue([h for h in rp.gate(s, None, "x") if h["rule"] in ("users-path", "volumes-path")], s)
        for s in (U + "Shared/x", U + "Shared", U + "Public", '"' + U + 'Public"', U + "<USER>/Desktop", U + "<USER>",
                  U + "crossover/x", U + "Shared and /tmp/x", "/Volumes/<VOLUME-1>/x", "/Volumes/<VOLUME-2>",
                  "C:\\Users\\Public\\Documents", "Z:\\Users\\<USER>\\x", "C:\\users\\crossover\\AppData",
                  "Z:\\Users\\<USER>\r\nnext", "/Volumes/<VOLUME-1>\r\n", "see " + U + "Shared. Then", U + "Public:"):
            self.assertEqual(rp.gate(s, None, "x"), [], s)

    def test_json_string_values(self):
        ident = rp.learn_identity({"login": "zo\u00eb", "adsk_user": "J\u00fcrgen42", "gecos": "\U0001d49cna Lima"})
        doc = json.dumps({"checks": [{"id": "a", "title": "ok"}, {"id": "b", "title": "for J\u00fcrgen42"}]}, indent=1)
        self.assertNotIn("J\u00fcrgen", doc)   # only as \u00fc: no literal search finds it
        hits = rp.gate(doc.encode("ascii"), ident, "doctor.json")
        self.assertEqual({(h["rule"], h["class"]) for h in hits}, {("learned", "adsk_user")})
        self.assertEqual({h["line"] for h in hits}, {n for n, s in enumerate(doc.split("\n"), 1) if "J\\u00fc" in s})
        nd = "\n".join(json.dumps({"n": i, "who": "zo\u00eb" if i == 3 else "x"}) for i in range(5))
        self.assertEqual({(h["rule"], h["line"], h["class"]) for h in rp.gate(nd, ident, "runs.ndjson")},
                         {("learned", 4, "user")})
        pair = json.dumps({"by": "\U0001d49cna Lima"})   # a surrogate pair in the escape
        self.assertIn("\\ud835", pair)
        self.assertTrue([h for h in rp.gate(pair, ident, "x") if h["class"] == "name"])
        self.assertTrue(rp.gate('log line {"p": "\\/Users\\/bob"} end', None, "x"))
        self.assertEqual(rp.gate(json.dumps({"a": "banana", "b": ["analysis"]}), rp.learn_identity({"login": "ana"}),
                                 "x"), [])

    def test_anchored_fields_agree_with_the_redaction(self):
        ident = rp.learn_identity({"login": "jo"})
        raw = {"user-key": "Property(S): USERNAME = Someone Else", "host-key": "ComputerName=STUDIO7",
               "host-found": "found for host STUDIO7: x", "attr-username": "Rvt.Attr.Username: someone7",
               "owner": "RegOwner = Big Client Ltd", "consent-id": "ADPSDK\\UserConsent\\ABCDEF123456.json",
               "learned": "USER=jo LOGNAME: jo"}
        for rule, s in raw.items():
            self.assertIn(rule, [h["rule"] for h in rp.gate(s, ident, "x")], rule)
            out = rp.redact(s, ident)[0]
            self.assertNotEqual(out, s, rule)
            self.assertEqual(rp.gate(out, ident, "x"), [], rule)
        for s in ("LogonUser = crossover", "Property(S): USERNAME=SYSTEM", "USER=joe", "user jo", "ComputerName=<HOST>",
                  "Rvt.Attr.Username: <ADSK-USER>"):
            self.assertEqual(rp.gate(s, ident, "x"), [], s)
            self.assertEqual(rp.redact(s, ident)[0], s, s)


class ShortLogin(Tmp):
    def test_login_ana_keeps_longer_words_and_the_archive_passes_the_gate(self):
        home = self.path("home")
        data = os.path.join(home, "revit-macos")
        inst = os.path.join(data, "logs", "rvt2027-a", "20261014-145128-install")
        os.makedirs(inst)
        for name, text in (("summary.txt", "   licensing  exit=1     banana analysis (56 s)\n"),
                           ("failed.txt", "licensing\n"),
                           ("licensing.log", "!! banana and analysis failed\n!! for ana in %s/Library\n"
                                             "Error 1603 by ana; Ana's analysis\n" % home)):
            with open(os.path.join(inst, name), "w") as f:
                f.write(text)
        ident = rp.learn_identity({"login": "ana", "home": home, "data": data})
        r = rp.build(REPO, data, self.path("none"), os.path.join(data, "logs", "rvt2027-a", "20261016-120000-report"),
                     year="2027", bottle="rvt2027-a", identity=ident, now=NOW)
        self.assertIsNone(r["refused"])
        self.assertEqual(r["left_out"], [])
        with zipfile.ZipFile(r["report_zip"]) as z:
            members = {n: z.read(n) for n in z.namelist()}
        self.assertEqual(members["install/licensing-errors.txt"].decode(),
                         "line 1: !! banana and analysis failed\nline 2: !! for <USER> in ~/Library\n"
                         "line 3: Error 1603 by <USER>; <USER>'s analysis")
        self.assertIn("banana analysis", members["install/summary.txt"].decode())
        for n, b in members.items():
            self.assertEqual(rp.gate(b, ident, n), [], n)
        self.assertEqual(rp._gate_file(r["report_zip"], ident, "report.zip"), [])
        self.assertEqual(rp.gate(slurp(r["report_txt"], "rb"), ident, "report.txt"), [])
        for planted in ("by ana", "Ana's", U + "ana/x", "Z:\\Users\\ana\\x", "USER=ana"):
            self.assertTrue(rp.gate(planted, ident, "x"), planted)


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

    def test_msi_error_lines_and_properties(self):
        log = self.msi_log() + ["Property(S): TRANSFORMS = " + win(U + "design/x.mst")]
        out = rp.msi_extract(log)
        text = "\n".join(out)
        errors = [s for s in out if s.startswith("line ")]
        self.assertEqual(len(errors), 36)   # 12 x (Error 1722, returned actual error code, Return value 3)
        for s in errors:
            n, line = re.match(r"^line (\d+): (.*)$", s).groups()
            self.assertEqual(log[int(n) - 1], line)
        self.assertIn("Property(S): ProductVersion = 27.3.0.28", text)
        self.assertIn("Property(S): ADLM_PRODKEY = 829S1", text)
        self.assertIn("Property(S): TRANSFORMS = (not shown)", text)
        for gone in ("ComputerName", "USERNAME", "SourceDir", "LogonUser", "not a tail", "Action start", "Step0.",
                     "Verbose logging", "Return value 1", "design"):
            self.assertNotIn(gone, text)
        self.assertEqual(rp.msi_extract(["Action ended 1: X. Return value 1.", "Property(S): ProductVersion = 1"]), [])

    def test_error_lines_only_and_capped(self):
        lines = []
        for i in range(300):
            lines += ["plain line %d about the client project" % i, "  !! step %d failed" % i]
        lines += ["   fonts      exit=1     winetricks (76 s)", "   rvt        exit=0     RVT.msi (8 s)",
                  "   apps       exit=skip  (0 s)", "it exit=1 here, not a summary line", "Exception occurred in OGS",
                  "Error 12 is short", "unrecoverable error", "0024:err:eventlog:ReportEventW (x)", "a captureTryCrash",
                  "Assertion failed: x", "wine: Unhandled page fault on read access", "Return value 3."]
        out = rp.error_extract(lines)
        self.assertEqual(len(out), rp.ERROR_LINES + 1)
        self.assertEqual(out[0], "line 2:   !! step 0 failed")
        self.assertEqual(out[rp.ERROR_LINES // 2], "\u2026 208 more error lines not kept")
        self.assertEqual(out[-1], "line 612: Return value 3.")
        tail = "\n".join(out[-10:])
        for keep in ("fonts      exit=1", "Exception occurred", "unrecoverable error", "ReportEventW", "captureTryCrash",
                     "Assertion failed", "Unhandled page fault"):
            self.assertIn(keep, tail)
        for gone in ("plain line", "exit=0", "exit=skip", "not a summary", "Error 12"):
            self.assertNotIn(gone, "\n".join(out))
        self.assertEqual(rp.error_extract(["fine", "all good"]), [])

    def test_error_file_big_log_in_blocks(self):
        old = rp.SCAN_BLOCK
        rp.SCAN_BLOCK = 4096   # many blocks, lines across block ends
        try:
            with tempfile.TemporaryDirectory() as d:
                lines = ["body %d %s" % (i, "y" * (i % 97)) for i in range(5000)]
                for n in (17, 2999, 4999):
                    lines[n] = "!! failure at %d" % n
                lines[1000] = "z" * 20000   # longer than four blocks: line numbers after it stay right
                lines[3000] = "x" * 3000 + " Error 1603 at the end of a long line"
                p = os.path.join(d, "big.log")
                with open(p, "w") as f:
                    f.write("\n".join(lines))   # no line end at the end
                out = rp.error_file(p)
                with open(p, "wb") as f:
                    f.write(b"\xff\xfe" + "one\r\n!! two\r\n".encode("utf-16-le"))
                self.assertEqual(rp.error_file(p), ["line 2: !! two"])
        finally:
            rp.SCAN_BLOCK = old
        self.assertEqual([s.split(":")[0] for s in out], ["line 18", "line 3000", "line 3001", "line 5000"])
        self.assertEqual(out[0], "line 18: !! failure at 17")
        self.assertTrue(out[2].endswith(" Error 1603 at the end of a long line"))   # whole: redacted, then cut
        self.assertTrue(out[2].startswith("line 3001: xxx") and len(rp._cut_line(out[2])) <= rp.LINE_MAX)

    def test_error_file_cut_short_while_read(self):
        real = os.fstat

        class Grown:   # the size when opened is larger than what is there to read: the file was cut short
            def __init__(self, st):
                self.st_size = st.st_size + 5000
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.log")
            with open(p, "w") as f:
                f.write("one\n!! two\nthree\n")   # ends with a line end: nothing carried over
            rp.os.fstat = lambda fd: Grown(real(fd))
            try:
                out = rp.error_file(p)
            finally:
                rp.os.fstat = real
        self.assertEqual(out, ["line 2: !! two"])

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

    def cxlog(self):
        lines = self.cx_header("Wed Oct 14 15:08:19 2026")
        lines[1] += " 'C:\\x\\Error 1234 Tower.rvt'"   # an error word in the header: the header never goes out
        lines += ["540731.357:04a8:02d8:trace:module:load %d" % i for i in range(300)]
        lines += ["** Wed Oct 14 15:08:21 2026",   # the short header of the launch that follows the full one
                  "Starting '/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader' "
                  "'C:\\users\\crossover\\Documents\\Tower.rvt'", ""]
        lines += ["0024:err:module:import_dll Library not found %d" % i for i in range(20)]
        lines += ["wine: Unhandled page fault on read access to 0000000000000000 at address 00006FFFFF (thread 0024)",
                  "0024:err:eventlog:ReportEventW L\"Application: Revit.exe\"", "Assertion failed: (0), function x",
                  "0024:trace:seh:dispatch_exception code=c0000005 flags=0"]
        return lines

    def test_cxlog_header_fields_and_error_lines(self):
        lines = self.cxlog()
        out = rp.cxlog_extract(lines)
        text = "\n".join(out)
        for gone in ("Environment", "CXConfig", "Starting", "Command:", "WINEPREFIX", "/Volumes", "Tower", "client-x",
                     "Grabbing", "/usr/bin", "Library not found", "load 299", "dispatch_exception", "Error 1234"):
            self.assertNotIn(gone, text)
        for keep in ("2 headers; their fields:", "Product version: 26.3.0.39832", "Mode: private", "PATH: 4 entries",
                     "CX_DEBUGMSG: err,+seh", "backend: default", "Error lines: 3"):
            self.assertIn(keep, text)
        errors = [s for s in out if s.startswith("line ")]
        self.assertEqual([int(s.split(":")[0][5:]) for s in errors], [len(lines) - 3, len(lines) - 2, len(lines) - 1])
        self.assertTrue(errors[0].endswith("wine: Unhandled page fault on read access to 0000000000000000 at address "
                                           "00006FFFFF (thread 0024)"))

    def test_cxlog_file_big_and_small(self):
        lines = self.cxlog()
        small = rp.cxlog_extract(lines)
        big = lines[:-4] + ["540731.357:04a8:02d8:trace:module:load %s" % ("y" * 200)] * 6000 + lines[-4:]
        old = rp.SCAN_BLOCK
        rp.SCAN_BLOCK = 8192
        try:
            with tempfile.TemporaryDirectory() as d:
                p = os.path.join(d, "wine.cxlog")
                with open(p, "w") as f:
                    f.write("\n".join(lines) + "\n")
                self.assertEqual(rp.cxlog_file(p), small)
                with open(p, "w") as f:
                    f.write("\n".join(big) + "\n")
                self.assertGreater(os.path.getsize(p), 1 << 20)
                out = rp.cxlog_file(p)
        finally:
            rp.SCAN_BLOCK = old
        self.assertEqual(out[:8], small[:8])   # the header fields
        self.assertEqual([s.split(":")[0] for s in out if s.startswith("line ")],
                         ["line %d" % n for n in (len(big) - 3, len(big) - 2, len(big) - 1)])
        self.assertNotIn("Error 1234", "\n".join(out))


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
        self.write(inst + "/licensing.log", "installing for design on Anas-Studio, client Falcon Tower\n"
                   "!! the licensing installer returned 1603 for design on Anas-Studio\n"
                   "Error 1920 in %s\\x\n!! copied from /Volumes/Work Disk/a\nplain line: the Falcon project\n"
                   % win(self.home + "/Desktop"))
        self.write(inst + "/action-steps.log", "running fonts for the Falcon project\n  !! steps failed: fonts\n")
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
        cx += ["wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001000 (thread 0024),"
               " starting debugger... on Anas-Studio"]
        self.write(dbg + "/wine.cxlog", "\n".join(cx) + "\n")
        self.write(dbg + "/stdout.log", "started for the Falcon project\nAssertion failed: x, as design\n")
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
        self.assertEqual(names, ["bottle/journal-extract.txt", "bottle/revit-ini.txt", "bottle/runs.ndjson",
                                 "debug/stdout-errors.txt", "debug/wine-cxlog.txt", "install/action-steps-errors.txt",
                                 "install/failed.txt", "install/licensing-errors.txt", "install/rvt-msi-errors.txt",
                                 "install/summary.txt", "manifest.txt", "test/result.json"])
        for n in names:
            self.assertIsNone(rp.REFUSE_RX.search(n), n)
        everything = rt + "\n".join(n + "\n" + b.decode("utf-8") for n, b in members.items())
        self.assertEqual(leftovers(everything, self.values()), [])
        self.assertEqual(rp.gate(rt, self.ident, "report.txt"), [])
        for n, b in members.items():
            self.assertEqual(rp.gate(b, self.ident, n), [], n)
        self.assertNotIn("Falcon", everything)   # a log's other lines never go out
        lic = members["install/licensing-errors.txt"].decode().split("\n")
        self.assertEqual(lic, ["line 2: !! the licensing installer returned 1603 for <USER> on <HOST>",
                               "line 3: Error 1920 in ~\\Desktop\\<DIR-1>",
                               "line 4: !! copied from /Volumes/<VOLUME-1>/a"])
        self.assertEqual(members["install/action-steps-errors.txt"].decode(), "line 2:   !! steps failed: fonts")
        self.assertEqual(members["install/rvt-msi-errors.txt"].decode().split("\n"),
                         ["line 3: MSI (s): Error 1722. problem", "line 4: Action ended 1: A. Return value 3.",
                          "--- properties ---", "Property(S): ProductVersion = 27.3.0.28"])
        self.assertEqual(members["debug/stdout-errors.txt"].decode(), "line 2: Assertion failed: x, as <USER>")
        cx = members["debug/wine-cxlog.txt"].decode()
        self.assertIn("Error lines: 1\nline 267: wine: Unhandled page fault on read access", cx)
        self.assertTrue(cx.endswith("starting debugger... on <HOST>"))
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
        with open(os.path.join(self.data, "logs/client-x/20261014-145128-install/summary.txt"), "a") as f:
            f.write("   extra      exit=0     copied from %sbob/Desktop\n" % U)
        r = self.build()
        self.assertIsNone(r["refused"])
        members = self.zip_members(r["report_zip"])
        self.assertNotIn("install/summary.txt", members)
        self.assertEqual([x["member"] for x in r["left_out"]], ["install/summary.txt"])
        self.assertTrue(all(h["rule"] == "users-path" for h in r["left_out"][0]["hits"]))
        rt = slurp(r["report_txt"])
        self.assertIn("Left out: summary.txt of the install log \u2014 it holds personal data that could not be "
                      "removed.", rt)
        self.assertIn("install/summary.txt \u2014 summary.txt of the install log: it holds personal data",
                      members["manifest.txt"].decode())
        self.assertNotIn("bob", rt + members["manifest.txt"].decode())

    def test_error_line_with_a_leak_is_left_out_alone(self):
        with open(os.path.join(self.data, "logs/client-x/20261014-145128-install/licensing.log"), "a") as f:
            f.write("!! copied from %sbob/Desktop\nError 1603 after it\n" % U)
        r = self.build()
        self.assertIsNone(r["refused"])
        self.assertEqual(r["left_out"], [])
        members = self.zip_members(r["report_zip"])
        lic = members["install/licensing-errors.txt"].decode().split("\n")
        self.assertEqual(lic[-2:], ["line 7: Error 1603 after it",
                                    "\u2026 1 line left out: personal data that could not be removed"])
        self.assertEqual(len(lic), 5)
        rt = slurp(r["report_txt"])
        self.assertIn("Left out: 1 line of the error lines of licensing.log \u2014 personal data that could not be "
                      "removed.", rt)
        manifest = members["manifest.txt"].decode()
        self.assertIn("install/licensing-errors.txt \u2014 error lines of licensing.log (from ", manifest)
        self.assertIn("; 1 line left out\n", manifest)
        self.assertNotIn("bob", rt + "".join(b.decode() for b in members.values()))

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

    def wineserver_files(self):
        lines = ["2026-10-27T10:00:%02d+0100 1-2 line %d" % (i % 60, i) for i in range(400)]
        lines[-2] = "2026-10-27T10:00:00+0100 1-2 err: %s/Library/x.dll for design on Anas-Studio" % self.home
        lines[-3] = "2026-10-27T10:00:00+0100 1-2 " + "x" * (rp.LINE_MAX + 100)
        self.write("Bottles/client-x/revit-macos/wineserver.log", "\n".join(lines) + "\n")
        self.write("Bottles/client-x/revit-macos/wineserver.last",
                   '{"gen":3,"id":"1-2","start":1,"end":2,"class":"signal","exit":null,"signal":9}\n')

    def test_the_wineserver_log(self):
        self.wineserver_files()
        r = self.build()
        members = self.zip_members(r["report_zip"])
        log = members["bottle/wineserver.log"].decode().split("\n")
        self.assertEqual(len(log), 300)   # its last 300 lines
        self.assertEqual(log[0], "2026-10-27T10:00:40+0100 1-2 line 100")
        self.assertEqual(log[-1], "2026-10-27T10:00:39+0100 1-2 line 399")
        self.assertLessEqual(max(len(x) for x in log), rp.LINE_MAX)   # a long line is cut, as in every member
        self.assertIn("err: ~/Library/x.dll for <USER> on <HOST>", log[-2])
        self.assertEqual(members["bottle/wineserver-last.json"].decode(),
                         '{"gen":3,"id":"1-2","start":1,"end":2,"class":"signal","exit":null,"signal":9}')
        self.assertIn("to its last 300 lines", members["manifest.txt"].decode())
        for n, b in members.items():
            self.assertEqual(rp.gate(b, self.ident, n), [], n)

    def test_the_wineserver_log_left_out(self):
        self.wineserver_files()
        r = self.build(exclude=["wineserver.log", "wineserver-last.json"])
        members = self.zip_members(r["report_zip"])
        self.assertNotIn("bottle/wineserver.log", members)
        self.assertNotIn("bottle/wineserver-last.json", members)

    def test_exclude(self):
        r = self.build(exclude=["licensing.log"])
        self.assertNotIn("install/licensing-errors.txt", self.zip_members(r["report_zip"]))
        self.assertIn("left out on request", self.zip_members(r["report_zip"])["manifest.txt"].decode())

    def test_size_caps(self):
        inst = os.path.join(self.data, "logs/client-x/20261014-145128-install")
        with open(os.path.join(inst, "licensing.log"), "w") as f:
            for i in range(4000):
                f.write("!! line %d %s\n" % (i, "x" * 3000))
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
        with open(os.path.join(self.data, "logs/client-x/20261015-090000-test/result.json"), "wb") as f:
            f.write(b"\x00" * 3000 + b"\nend\n")
        r = self.build()
        self.assertIn({"member": "test/result.json", "what": "result of the test run",
                       "reason": "it is not a text file", "hits": []}, r["left_out"])

    def test_logs_without_error_lines_add_nothing(self):
        dbg = os.path.join(self.data, "logs/client-x/20261001-101010-debug")
        inst = os.path.join(self.data, "logs/client-x/20261014-145128-install")
        for p, text in ((os.path.join(dbg, "stdout.log"), "started\nall fine\n"),
                        (os.path.join(inst, "licensing.log"), "the licensing service started\n")):
            with open(p, "w") as f:
                f.write(text)
        members = self.zip_members(self.build()["report_zip"])
        self.assertNotIn("debug/stdout-errors.txt", members)
        self.assertNotIn("install/licensing-errors.txt", members)
        manifest = members["manifest.txt"].decode()
        self.assertIn("20261001-101010-debug/stdout.log \u2014 stdout.log without an error line: nothing to add",
                      manifest)
        self.assertIn("20261014-145128-install/licensing.log \u2014 a failed step's log without an error line",
                      manifest)

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


class NoYear(Tmp):
    """./revit report without a year: custom bottle names and the Autodesk identity of every bottle are learned from
    the material itself; the identity given knows neither."""

    def test_any_bottle_folder_name_is_learned(self):
        long_ = "Tower-" + "x" * 66                   # 72 characters, more than ./revit takes
        odd = "Falcon Tower (main) 2026"              # spaces and brackets: CrossOver takes any name but '/'
        bottles = os.path.join(self.d, "Bottles")
        for n in (long_, odd, odd + ".test"):
            os.makedirs(os.path.join(bottles, n))
        ident = rp.learn_bottles(rp.learn_identity({}), self.d, bottles)
        text = "run in bottle %s, then %s and %s.test" % (long_, odd, odd)
        out = rp.redact(text, ident)[0]
        self.assertNotIn("Tower", out)
        self.assertNotIn("Falcon", out)
        self.assertEqual(rp.gate(out, ident), [])
        self.assertTrue(rp.gate(text, ident))         # the gate knows them too

    def test_a_long_name_from_logs_alone_is_learned(self):
        gone = "Removed-" + "y" * 64                  # its bottle is gone, its logs stay in logs/<name>/
        os.makedirs(os.path.join(self.d, "logs", gone, "20261016-111128-test"))
        ident = rp.learn_bottles(rp.learn_identity({}), self.d, os.path.join(self.d, "no such Bottles"))
        text = '{"bottle": "%s", "copy": "%s.test"} logs/%s/20261016-111128-test' % (gone, gone, gone)
        out = rp.redact(text, ident)[0]
        self.assertNotIn("Removed", out)
        self.assertEqual(rp.gate(out, ident), [])

    def setUp(self):
        super().setUp()
        self.home, self.bottles = self.path("home"), self.path("Bottles")
        self.data = self.path("home", "Work Files", "revit-macos")
        os.makedirs(self.data)
        for name, user, uid in (("Falcon-Tower", "alima42", "QWERTY1234567890"),
                                ("rvt2026-a", "bwong77", "ZXCVBN0987654321")):
            year = "2027" if name == "Falcon-Tower" else "2026"
            b = "Bottles/%s/drive_c/" % name
            ini = "[Partitions]\r\nUsername=%s\r\nUserId=%s\r\n" % (user, uid)
            self.write(b + "users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit %s/Revit.ini" % year,
                       b"\xff\xfe" + ini.encode("utf-16-le"))
            self.write(b + "users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit %s/Journals/journal.0001.txt"
                       % year, "' Build: x\nJrn.Directive  _\n        \"Username\"  , \"%s\"\n" % user)
            os.makedirs(self.path(*(b + "Program Files/Autodesk/Revit %s" % year).split("/")))
        logs = "home/Work Files/revit-macos/logs/"
        self.write(logs + "Falcon-Tower/20261014-145128-install/summary.txt",
                   "   bottle     exit=0     scripts/new-bottle.sh 2027 Falcon-Tower (23 s)\n")
        self.write(logs + "Falcon-Tower/20261015-090000-test/result.json",
                   json.dumps({"verdict": "pass", "bottle": "Falcon-Tower", "copy": "Falcon-Tower.test"}))
        self.write(logs + "rvt2026-a/20261012-101010-debug/stdout.log",
                   "Assertion failed: x for bwong77 and alima42\n!! stopped in Falcon-Tower\n")
        self.doc = self.path("doctor.json")
        with open(self.doc, "w") as f:
            json.dump({"checks": [
                {"id": "bottles.clone.Harbor-Lab.test", "status": "warn",
                 "title": "a temporary copy of Harbor-Lab that ./revit test made was left behind: Harbor-Lab.test",
                 "fix": "rm -rf \"$HOME/Library/Application Support/CrossOver/Bottles/Harbor-Lab.test\""},
                {"id": "bottles.Falcon-Tower", "status": "warn", "title": "Falcon-Tower: Revit 2027"}]}, f)
        self.ident = rp.learn_identity({"login": "design", "home": self.home, "data": self.data, "root": REPO})
        self.secret = ["falcon-tower", "harbor-lab", "alima42", "bwong77", "qwerty1234567890", "zxcvbn0987654321"]

    def test_bottle_names_and_autodesk_identity_are_learned(self):
        r = rp.build(REPO, self.data, self.bottles, self.path("out"), doctor_json=self.doc, identity=self.ident,
                     now=NOW)
        self.assertIsNone(r["refused"])
        with zipfile.ZipFile(r["report_zip"]) as z:
            members = {n: z.read(n).decode("utf-8") for n in z.namelist()}
        self.assertIn("test/result.json", members)
        self.assertIn("debug/stdout-errors.txt", members)
        everything = (slurp(r["report_txt"]) + "".join(n + "\n" + b for n, b in members.items())).lower()
        for v in self.secret:
            self.assertNotIn(v, everything, "a learned value is left (%d characters)" % len(v))
        self.assertIn("<BOTTLE>", members["test/result.json"])
        self.assertIn("<BOTTLE>.test", members["doctor.json"])
        self.assertIn("for <ADSK-USER> and <ADSK-USER>", members["debug/stdout-errors.txt"])
        self.assertIn("rvt2026-a", members["manifest.txt"])   # a default name is not personal

    def test_gate_command_learns_them_too(self):
        p = self.write("x.txt", "fine\nleft in Falcon-Tower by bwong77\n")
        env = {k: v for k, v in os.environ.items() if k not in ("REVIT_DATA", "REVIT_CX")}
        env["HOME"] = self.home
        r = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "report.py"), "gate", "--data", self.data,
                            "--bottles", self.bottles, p], capture_output=True, text=True, env=env, cwd="/")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(sorted(r.stdout.split()), sorted(["learned", "x.txt", "2", "bottle", "12",
                                                           "learned", "x.txt", "2", "adsk_user", "7"]))


class RunFolders(Tmp):
    def test_same_second_runs_take_the_suffixed_one(self):
        logs = self.path("data", "logs", "rvt2027-a")
        for n in ("20261014-145128-install", "20261014-145128-install-2", "20261014-145127-debug",
                  "20261014-145127-3-debug", "20261014-145127-debug-2"):
            os.makedirs(os.path.join(logs, n))
        picked = dict(rp._pick(rp._runs(self.path("data"), None)))
        self.assertEqual(os.path.basename(picked["install"]), "20261014-145128-install-2")
        self.assertEqual(os.path.basename(picked["debug"]), "20261014-145127-3-debug")   # the old form still read
        self.assertIsNotNone(rp._folder_time(os.path.join(logs, "20261014-145128-install-2")))
        self.assertEqual(rp._folder_time(os.path.join(logs, "20261014-145128-install-2")),
                         rp._folder_time(os.path.join(logs, "20261014-145128-install")))

    def test_build_reads_the_second_run_of_a_second(self):
        data = self.path("data")
        base = "data/logs/rvt2027-a/20261014-145128-install"
        self.write(base + "/summary.txt", "   rvt        exit=0     first (8 s)\n")
        self.write(base + "-2/summary.txt", "   rvt        exit=0     second (8 s)\n")
        r = rp.build(REPO, data, self.path("none"), self.path("out"), year="2027", bottle="rvt2027-a",
                     identity=rp.learn_identity({}), now=NOW)
        with zipfile.ZipFile(r["report_zip"]) as z:
            self.assertIn("second", z.read("install/summary.txt").decode())


class GitReadOnly(Tmp):
    def test_every_git_call_takes_no_optional_locks(self):
        calls, real = [], rp.subprocess.run

        def spy(cmd, *a, **k):
            calls.append((cmd, k.get("env")))
            return subprocess.CompletedProcess(cmd, 0, stdout="abc1234\n" if "rev-parse" in cmd else "")
        os.makedirs(self.path("repo", ".git"))
        rp.subprocess.run = spy
        try:
            rp._engine(self.path("repo"))
            rp.machine_facts(self.path("repo"), self.path("data"))
        finally:
            rp.subprocess.run = real
        git = [(c, e) for c, e in calls if os.path.basename(c[0]) == "git"]
        self.assertGreaterEqual(len(git), 4)
        for c, e in git:
            self.assertEqual(c[1], "--no-optional-locks", c[1:3])
            self.assertEqual((e or {}).get("GIT_OPTIONAL_LOCKS"), "0")

    @unittest.skipUnless(os.path.exists("/Library/Developer/CommandLineTools/usr/bin/git") or
                         sys.platform != "darwin", "git from the Command Line Tools")
    def test_engine_leaves_the_index_alone(self):
        repo = self.path("repo")
        os.makedirs(repo)
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
                   GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t" + AT + "example.com", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t" + AT + "example.com")
        for cmd in (["init", "-q"], ["add", "."], ["commit", "-qm", "x"]):
            if cmd[0] == "add":
                self.write("repo/f.txt", "one\n")
            subprocess.run(["git", "-C", repo] + cmd, env=env, check=True, capture_output=True)
        idx = os.path.join(repo, ".git", "index")
        os.utime(idx, (1000000000, 1000000000))
        os.utime(os.path.join(repo, "f.txt"), (1000000500, 1000000500))   # stat data that git status would refresh
        before = os.stat(idx).st_mtime_ns
        self.assertTrue(rp._engine(repo).startswith("git:"))
        self.assertEqual(os.stat(idx).st_mtime_ns, before)


class Trackpad(Build):
    """The app's trackpad helper: its log, the log before it (their ends) and its state go into the report. Build's
    fixture; Build's own tests are not run again (switched off below the class)."""
    D = "home/Work Files/revit-macos/"

    def test_log_and_state(self):
        self.write(self.D + "logs/trackpad.log", "2026-10-26T10:00:00Z started\n2026-10-26T10:00:01Z view AfxFrameOrView140u\n"
                   "2026-10-26T10:00:02Z hittest client-x: no answer twice, see %s/Library/x\n" % self.home)
        self.write(self.D + "logs/trackpad.log.1", "2026-10-25T09:00:00Z started\n")
        self.write(self.D + "trackpad/state.json", json.dumps({"session": "s", "pid": 1, "start": "x", "trusted": True,
                   "posting": True, "tap": True, "bottles": {"client-x": {"ready": True}}}))
        m = self.zip_members(self.build()["report_zip"])
        for n in ("trackpad/trackpad.log", "trackpad/trackpad.log.1", "trackpad/state.json"):
            self.assertIn(n, m)
        t = m["trackpad/trackpad.log"].decode()
        self.assertIn("view AfxFrameOrView140u", t)
        self.assertNotIn(self.home, t); self.assertNotIn("client-x", t)
        self.assertIn('"tap": true', m["trackpad/state.json"].decode().replace('"tap":true', '"tap": true'))

    def test_a_long_log_gives_its_end(self):
        self.write(self.D + "logs/trackpad.log", "".join("2026-10-26T10:00:00Z line %d\n" % i for i in range(3000)))
        t = self.zip_members(self.build()["report_zip"])["trackpad/trackpad.log"].decode()
        self.assertIn("line 2999", t); self.assertNotIn("line 0\n", t)

    def test_no_trackpad_files(self):
        self.assertFalse([n for n in self.zip_members(self.build()["report_zip"]) if n.startswith("trackpad/")])


for _n in [n for n in vars(Build) if n.startswith("test_")]:
    setattr(Trackpad, _n, None)


class JournalBounded(unittest.TestCase):
    def test_kept_lines_are_cut_as_before(self):
        lines = ["' Build: 20260907_1515(x64)", "' Release: 2027.3"]
        lines += ["'C 12-Oct-2026 23:59:%02d.000;   0:< Exception occurred %d" % (i % 60, i) for i in range(1500)]
        out = rp.journal_extract(iter(lines))
        self.assertEqual(out[:3], ["' Build: 20260907_1515(x64)", "' Release: 2027.3", "\u2026 502 kept lines cut"])
        self.assertEqual(len(out), 3 + rp.JOURNAL_MAX)
        self.assertTrue(out[-1].endswith("Exception occurred 1499"))

    def test_memory_stays_bounded(self):
        import tracemalloc

        def many():
            yield "' Build: 20260907_1515(x64)"
            for i in range(60000):
                yield "'C 12-Oct-2026 23:59:00.000;   0:< Exception occurred in a long line %d %s" % (i, "y" * 200)
            yield "Jrn.Data  _"
            for i in range(60000):   # one statement that never ends
                yield '        "File Name"  , "IDOK" , "%s" _' % ("z" * 200)
            yield "' 0:< finished recording journal file"
        tracemalloc.start()
        try:
            out = rp.journal_extract(many())
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 4 << 20)
        self.assertEqual(out[0], "' Build: 20260907_1515(x64)")
        self.assertLessEqual(len(out), rp.JOURNAL_MAX + 3)

    def test_a_huge_journal_is_read_by_its_head_and_tail(self):
        old = rp.JOURNAL_READ
        rp.JOURNAL_READ = 64 << 10
        try:
            with tempfile.TemporaryDirectory() as d:
                p = os.path.join(d, "journal.0001.txt")
                with open(p, "w") as f:
                    f.write("' Build: 20260907_1515(x64)\n' Release: 2027.3\n")
                    for i in range(20000):
                        f.write("' 0:< plain line %d about nothing much\n" % i)
                    f.write("'C 12-Oct-2026 23:59:09.000;   0:< Exception occurred at the end\n")
                    f.write("' 0:< a plain line after it\n")
                read, real = [], rp.bottleread.read_lines

                def spy(path, max_bytes=None, max_line=4000, start=0):
                    for ln in real(path, max_bytes, max_line, start):
                        read.append(len(ln) + 1)
                        yield ln
                rp.bottleread.read_lines = spy
                try:
                    out = rp.journal_file(p)
                finally:
                    rp.bottleread.read_lines = real
        finally:
            rp.JOURNAL_READ = old
        self.assertLess(sum(read), 80 << 10)
        self.assertEqual(out[:2], ["' Build: 20260907_1515(x64)", "' Release: 2027.3"])
        self.assertTrue(out[-2].endswith("Exception occurred at the end"))
        self.assertTrue(any(re.match(r"^\u2026 \d+ KB of the journal not read$", s) for s in out))


class Rev3Names(unittest.TestCase):
    """Apostrophes, brackets and colons in folder and model names; cloud folders under ~/Library."""

    def check(self, raw, want, ident=None):
        ident = ident or rp.learn_identity({"home": U + "design", "login": "design"})
        out = rp.redact(raw, ident)[0]
        self.assertEqual(out, want)
        self.assertEqual(rp.gate(out, ident, "x"), [], raw)
        self.assertTrue(rp.gate(raw, rp.learn_identity({}), "x"), raw)   # planted past the redaction: caught
        self.assertEqual(rp.redact(out, ident)[0], out)

    def test_apostrophe_bracket_colon(self):
        self.check("C:\\users\\crossover\\Documents\\O'Brien Architects\\Harbor Tower\\Phase 2\\notes.txt",
                   "C:\\users\\crossover\\Documents\\<DIR-1>\\<DIR-2>\\<DIR-3>\\<DIR-4>.txt")
        self.check("~/Desktop/Client's files/Harbor Tower/site.dwg", "~/Desktop/<DIR-1>/<DIR-2>/<MODEL-1>.dwg")
        self.check("C:\\ProjectsX\\Henderson's Barn.rvt", "C:\\ProjectsX\\<MODEL-1>.rvt")
        self.check("Y:\\Projects [2026]\\Harbor Tower\\x.txt", "Y:\\<DIR-1>\\<DIR-2>\\<DIR-3>.txt")
        self.check("0024:err:eventlog:ReportEventW L\"Could not find file 'C:\\\\users\\\\crossover\\\\Documents\\\\"
                   "O'Brien House (v2): final.rvt'.\"",
                   "0024:err:eventlog:ReportEventW L\"Could not find file 'C:\\\\users\\\\crossover\\\\Documents\\\\"
                   "<MODEL-1>.rvt'.\"")
        self.check("Error: 'C:\\users\\crossover\\Desktop\\Smith: Annex [old]\\plan.txt' not found",
                   "Error: 'C:\\users\\crossover\\Desktop\\<DIR-1>\\<DIR-2>.txt' not found")
        self.check("'C:\\users\\crossover\\Documents\\Brothers' Work\\plan.txt'",
                   "'C:\\users\\crossover\\Documents\\<DIR-1>\\<DIR-2>.txt'")
        self.check("[C:\\users\\crossover\\Desktop\\Client\\notes.txt] opened",
                   "[C:\\users\\crossover\\Desktop\\<DIR-1>\\<DIR-2>.txt] opened")
        self.check("see ~/Documents/Client/notes.txt: no such file", "see ~/Documents/<DIR-1>/<DIR-2>.txt: no such file")
        self.check("~/Documents/v1.2: final", "~/Documents/<DIR-1>")   # .2 is no extension: nothing of it stays
        out = rp.redact("opened Henderson's Barn.rvt", rp.learn_identity({}))[0]
        self.assertNotIn("Henderson", out)

    def test_gate_checks_what_follows_a_placeholder(self):
        for s in ("C:\\users\\crossover\\Documents\\<DIR-1>'Brien Architects\\Harbor Tower\\notes.txt",
                  "~/Desktop/<DIR-2>'s files/Harbor Tower/<MODEL-1>.dwg", "C:\\ProjectsX\\Henderson'<MODEL-1>.rvt",
                  "Y:\\<DIR-3> [2026]\\Harbor Tower\\x.txt", "~/Documents/<DIR-1>x/<DIR-2>.txt"):
            self.assertTrue(rp.gate(s, None, "x"), s)
        for s in ("~/Documents/<DIR-1>/<MODEL-1>.rvt and C:\\x\\<MODEL-2>.rfa", "~/Documents/<DIR-1>.txt: no such file",
                  "'~/Documents/<DIR-1>/<DIR-2>.txt' and '~/Desktop/<DIR-3>.txt'", "~/Documents/<DIR-1>, then"):
            self.assertEqual(rp.gate(s, None, "x"), [], s)

    def test_cloud_folders_under_library(self):
        ident = rp.learn_identity({"home": U + "design", "login": "design"})
        cases = [
            ("~/Library/CloudStorage/OneDrive-Harbor Architects/Projects/Smith Residence/notes.txt",
             "~/Library/CloudStorage/<DIR-1>/<DIR-2>/<DIR-3>/<DIR-4>.txt"),
            ("Y:\\Library\\CloudStorage\\Dropbox (Harbor)\\Clients\\Smith Residence\\a.txt",
             "Y:\\Library\\CloudStorage\\<DIR-1>\\<DIR-2>\\<DIR-3>\\<DIR-4>.txt"),
            ("Z:\\Users\\design\\Library\\CloudStorage\\GoogleDrive-someone\\My Drive\\Smith Residence\\a.txt",
             "~\\Library\\CloudStorage\\<DIR-1>\\<DIR-2>\\<DIR-3>\\<DIR-4>.txt"),
            (U + "design/Library/Mobile Documents/com~apple~CloudDocs/Clients/Smith Residence/a.dwg",
             "~/Library/Mobile Documents/com~apple~CloudDocs/<DIR-1>/<DIR-2>/<MODEL-1>.dwg"),
            ("Z:\\\\Users\\\\design\\\\Library\\\\CloudStorage\\\\OneDrive-Harbor\\\\Smith Residence\\\\x.txt",
             "~\\\\Library\\\\CloudStorage\\\\<DIR-1>\\\\<DIR-2>\\\\<DIR-3>.txt"),
            ('{"p": "\\/Users\\/design\\/Library\\/CloudStorage\\/Dropbox\\/Smith Residence\\/x.txt"}',
             '{"p": "~\\/Library\\/CloudStorage\\/<DIR-1>\\/<DIR-2>\\/<DIR-3>.txt"}'),
        ]
        for raw, want in cases:
            out = rp.redact(raw, rp.learn_identity({"home": U + "design", "login": "design"}))[0]
            self.assertEqual(out, want)
            self.assertEqual(rp.gate(out, ident, "x"), [], raw)
            planted = out.replace("<DIR-1>", "Harbor Firm")
            self.assertIn("user-dir", [h["rule"] for h in rp.gate(planted, None, "x")], raw)
        for s in ("~/Library/Application Support/CrossOver/Bottles/rvt2027-a/x.txt", "~/Library/Logs/x.log",
                  "~/Library/CloudStorage", "~/Library/Mobile Documents/com~apple~CloudDocs"):
            self.assertEqual(rp.redact(s, ident)[0], s)
            self.assertEqual(rp.gate(s, None, "x"), [], s)


class Rev3Minor(unittest.TestCase):
    def test_lines_are_redacted_before_they_are_cut(self):
        ident = rp.learn_identity({})
        mail = "mark.ostrowski" + AT + "harbor-arch.com"
        line = "!! " + "x " * 980 + mail + " rest"
        out = rp.redact("\n".join(rp.error_extract([line])), ident)[0]
        self.assertNotIn("harbor", out)
        self.assertIn("<EMAIL>", out)
        cut = rp._cut_line(out)
        self.assertLessEqual(len(cut), rp.LINE_MAX)
        self.assertNotIn("harbor", cut)
        with tempfile.TemporaryDirectory() as d:   # a line longer than the reader keeps: no part of a value left
            p = os.path.join(d, "x.log")
            with open(p, "w") as f:
                f.write("!! " + "y " * 1990 + "q" + mail + " and more\n")
            ex = rp.error_file(p)
            whole = rp._text(p)   # summary.txt and the like: the same
        self.assertNotIn("ostrowski", whole)
        self.assertEqual(len(ex), 1)
        self.assertNotIn("ostrowski", ex[0])
        self.assertIn("a line too long to check was left out", ex[0])

    def test_a_cut_line_leaves_no_part_of_a_value_of_several_words(self):
        ident = rp.learn_identity({"denylist": ["Harbor Residence"]})
        line = "!! " + "z " * 1994 + "Harbor Residence and more"   # the reader cuts it inside the name
        out = rp.redact("\n".join(rp.error_extract([line[:rp.READ_LINE]])), ident)[0]
        self.assertNotIn("Harbor", out)
        self.assertEqual(rp.gate(out, ident), [])

    def test_a_cut_never_splits_a_placeholder(self):
        for n in range(8):
            line = "C:\\users\\crossover\\Documents" + "x" * n + "\\<DIR-1>" * 300
            cut = rp._cut_line(line)
            self.assertTrue(cut.endswith(" \u2026[cut]"))
            self.assertLessEqual(len(cut), rp.LINE_MAX)
            self.assertIsNone(re.search(r"<[^<>]*$", cut[:-len(" \u2026[cut]")]), n)

    def test_autodesk_exemption_ends_with_the_path(self):
        ident = rp.learn_identity({"login": "anna", "hosts": ["Annas-Studio"]})
        raw = "!! C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe stopped for anna on Annas-Studio"
        out = rp.redact(raw, ident)[0]
        self.assertEqual(out, "!! C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe stopped for <USER> on <HOST>")
        self.assertIn("user", [h["class"] for h in rp.gate(raw.replace("Annas-Studio", "x"), ident, "x")])
        keep = ("C:\\Program Files\\Autodesk\\Revit 2027\\AddIns\\Anna Tools\\Anna.dll\n"
                "C:\\Windows\\Fonts\\Anna Sans.ttf\n")
        self.assertEqual(rp.redact(keep, ident)[0], keep)
        self.assertEqual(rp.gate(keep, ident, "x"), [])

    def test_wine_escapes(self):
        ident = rp.learn_identity({"volumes": ["J\u00fcrgens SSD"], "gecos": "Zo\u00eb J\u00fcrgen"})
        raw = "0024:err:eventlog:ReportEventW L\"Could not find file Z:\\\\Volumes\\\\J\\x00fcrgens SSD\\\\x\""
        out = rp.redact(raw, ident)[0]
        self.assertEqual(out, "0024:err:eventlog:ReportEventW L\"Could not find file Z:\\\\Volumes\\\\<VOLUME-1>\\\\x\"")
        self.assertTrue([h for h in rp.gate(raw, ident, "x") if h["class"] == "volume"])
        for raw in ("0024:err:x L\"by J\\x00fcrgen\"", "0024:warn:x \"by J\\xc3\\xbcrgen\""):
            out = rp.redact(raw, ident)[0]
            self.assertIn("by <NAME>", out)
            self.assertTrue([h for h in rp.gate(raw, ident, "x") if h["class"] == "name"], raw)
            self.assertEqual(rp.gate(out, ident, "x"), [])
        keep = "C:\\users\\crossover\\AppData\\x2026\\y\n0024:trace:x L\"C:\\\\x2026\""
        self.assertEqual(rp.redact(keep, rp.learn_identity({}))[0], keep)
        raw = "0024:err:x opened C:\\users\\crossover\\Documents\\x00e9\\plan.txt"   # a raw path: \x00e9 is a folder
        self.assertEqual(rp.redact(raw, rp.learn_identity({}))[0],
                         "0024:err:x opened C:\\users\\crossover\\Documents\\<DIR-1>\\<DIR-2>.txt")


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
