# SPDX-License-Identifier: MIT
"""Unit tests for tools/smoke.py and the journal templates in scripts/smoke/.
Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every journal, Revit.ini and output file is generated here; nothing from Autodesk or a real Revit run is needed."""
import datetime, importlib.util, json, os, subprocess, sys, tempfile, time, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
SMOKE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "smoke")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sm = load("smoke")
OLE = bytes.fromhex("d0cf11e0a1b11ae1")
MON = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
USER = "".join(["qz", "user", "7k"])   # a made-up Autodesk user name, put together here


def run(*args):
    return subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "smoke.py"), *args],
                          capture_output=True, text=True)


def replay(year=2027, played="core.txt", exit_at=19, stop=None, tail=None, finished=True, manage=True, update=True,
           license=True, idle=20.0, gap=3.0, strong=None, dialog=None, answered=False, modal_open=False, upto=None):
    """Lines like those of a journal Revit writes while it plays one, made up here. upto cuts it after a stage:
    licensing, idle, playback."""
    t0 = datetime.datetime(2026, 10, 16, 11, 11, 28, 123000)
    out = []

    def at(sec, text, kind="C", pad=""):
        t = t0 + datetime.timedelta(seconds=sec)
        out.append(f"{pad}'{kind} {t.day:02d}-{MON[t.month - 1]}-{t.year} {t:%H:%M:%S}.{t.microsecond // 1000:03d};"
                   f"  {text} ")

    out.append("' 0:< Initial VM: synthetic")
    at(0, "started recording journal file")
    out += ["' Build: 20991231_0000(x64)", f"' Branch: RELEASE_{year}" + ("" if year == 2020 else ".3")]
    if year != 2020:
        out.append(f"' Release: {year}.3")
    out += ["Dim Jrn", "Set Jrn = CrsJournalScript"]
    if manage:
        at(2, "  0:< manage licensing")
    if update:
        at(4, "  0:< " + ("LicenseUpd(1) " if year == 2020 else "License Update: (reason=1)"))
    if upto == "licensing":
        return out
    at(4.1, "  0:< Delayed start")
    if license:
        out += ["' 0:< License mode: User", "' 0:< Status: Your license will expire in 200 days."]
    at(6, "  0:< ", kind="H")
    out += ["Jrn.Directive  _", f'        "Username"  , "{USER}"']
    if upto == "idle":
        return out
    at(idle, "  0:< appPriv idle")
    at(idle + 0.1, f'started journal file playback of "C:\\revit-smoke\\{played}"')
    at(idle + 0.2, "  0:< ", kind="E", pad="  ")
    out.append('  Jrn.Command "Menu"  , "Create a new project , ID_FILE_NEW_CHOOSE_TEMPLATE" ')
    at(idle + 0.3, "  0:< ADialog::doModal start", pad="  ")
    out.append('    Jrn.PushButton "Modal , New Project , Dialog_Revit_NewProject"  _')
    if not modal_open:
        at(idle + 0.5, "  0:< ADialog::doModal stop", pad="  ")
    at(idle + 0.5 + gap, "  0:< Notify Active View.", pad="  ")
    t = idle + 1 + gap
    if strong:
        at(t, f"  0:< {strong}: synthetic")
    if dialog:
        text, did = dialog
        out += [f'  \' 1:< TaskDialog "{text}"', f"  'Id : {did}", "  'CommonButtons : Yes, No, Cancel"]
        if answered:
            at(t + 0.5, "  1:< ", kind="H", pad="  ")
            out += ["  Jrn.Data  _", f'          "TaskDialogResult"  , "{text}" ,  _', '           "No"  _']
    if upto == "playback" or modal_open:
        return out
    at(t + 1, "->desktop ExitNativeInstance")
    marker = "JOURNAL_MARKER_TAIL_END: " if (tail if tail is not None else year >= 2024) else ""
    at(t + 2, f"{marker}stopped at line {exit_at if stop is None else stop} journal file playback")
    at(t + 3, "<-desktop ExitNativeInstance")
    if finished:
        at(t + 4, "finished recording journal file")
    return out


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, *parts):
        p = os.path.join(self.d, *parts)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    def write(self, name, data):
        p = self.path(name)
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        return p


class Journal(Tmp):
    def test_version_directive_per_year(self):
        for year, ver, fmt in ((2020, "2020.000", "2.164"), (2023, "2023.000", "2.169"), (2025, "2025.000", "2.169"),
                               (2026, "2026.000", "2.179"), (2027, "2027.000", "2.179")):
            text = sm.make_journal("start", year)
            self.assertIn(f'Jrn.Directive "Version", "{ver}", "{fmt}"\r\n', text, year)

    def test_crlf_no_placeholder_and_exit_line_kept(self):
        tpl = "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\English\\Default-Multi-Discipline_Metric.rte"
        for scenario in ("start", "core", "reopen"):
            text = sm.make_journal(scenario, 2027, tpl)
            self.assertNotIn("{{", text)
            self.assertNotIn("\n", text.replace("\r\n", ""))
            out = self.path(scenario + ".txt")
            sm.write_journal(text, out)
            self.assertEqual(sm.exit_line(out), sm.exit_line(os.path.join(SMOKE, scenario + ".txt")), scenario)
            self.assertTrue(text.startswith(sm.PROVENANCE + "\r\n"))
        core = sm.make_journal("core", 2027, tpl)
        self.assertIn(f'"IDOK", "{tpl}", "rte", "Default-Multi-Discipline_Metric.rte", '
                      f'"Default-Multi-Discipline_Metric.rte"', core)
        self.assertIn('"C:\\revit-smoke\\out\\smoke.rvt"', core)
        self.assertIn('"C:\\revit-smoke\\out\\smoke2.rvt"', sm.make_journal("reopen", 2025))

    def test_refusals(self):
        with self.assertRaises(SystemExit):
            sm.make_journal("core", 2027)                         # needs a template
        with self.assertRaises(SystemExit):
            sm.make_journal("core", 2027, 'C:\\a "b".rte')        # a quote would end the journal string
        with self.assertRaises(SystemExit):
            sm.make_journal("core", 2027, "/tmp/a.rte")          # not a Windows path
        with self.assertRaises(SystemExit):
            sm.make_journal("start", 2022)                        # no known journal format
        with self.assertRaises(SystemExit):
            sm.make_journal("../core", 2027)
        with self.assertRaises(SystemExit):
            sm.write_journal(sm.make_journal("core", 2027, "C:\\T\\\u0428\u0430\u0431.rte"), self.path("j.txt"))

    def test_cli_writes_the_file(self):
        out = self.path("smoke-start.txt")
        r = run("journal", "start", "--year", "2024", "--out", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(out, "rb") as f:
            data = f.read()
        self.assertIn(b'"2024.000", "2.169"\r\n', data)
        self.assertEqual(run("journal", "core", "--year", "2024", "--out", out).returncode, 1)


class Lint(Tmp):
    GOOD = [sm.PROVENANCE, "Dim Jrn", "Set Jrn = CrsJournalScript",
            'Jrn.Directive "Version", "{{VERSION}}", "{{FORMAT}}"',
            'Jrn.Command "Internal", "Quit the application; prompts to save projects , ID_APP_EXIT"']

    def lint_lines(self, lines):
        return sm.lint([self.write("t.txt", "\n".join(lines) + "\n")])

    def test_repo_templates_pass(self):
        r = run("lint")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok (3 journals)", r.stdout)
        self.assertEqual(self.lint_lines(self.GOOD), [])

    def test_each_rule(self):
        cases = [
            ('Jrn.Directive "DebugMode", "PerformAutomaticActionInErrorDialog", 1', "answers dialogs"),
            ('Jrn.Directive "DebugMode", "PermissiveJournal", 1', "answers dialogs"),
            ('Jrn.Directive "Username", "someone"', "Username"),
            ("' 0:< License mode: User", "records a journal"),
            ("'C 16-Oct-2026 11:11:28.123;  started recording journal file", "timestamp line"),
            ("' Build: 20991231_0000(x64)", "header line"),
            ('Jrn.Directive  _', "line continuation"),
            ('Jrn.Data "File Name", "IDOK", "D:\\work\\a.rvt"', "absolute path"),
            ("' a model from C:\\Users\\someone\\a.rvt", "absolute path"),
            ('Jrn.Data "File Name", "IDOK", "\\\\server\\share\\a.rvt"', "outside"),
            ('Jrn.Data "File Name", "IDOK", "%USERPROFILE%\\a.rvt"', "outside"),
            ('Jrn.Command "Ribbon", "Sign in , ID_SIGN_IN"', "sign-in, licensing"),
            ('Jrn.Command "Internal", " , ID_LICENSE_MANAGER"', "sign-in, licensing"),
            ('Set fso = CreateObject("Scripting.FileSystemObject")', "not a Jrn line"),
            ("t0 = Timer", "not a Jrn line"),
            ("' caf\u00e9", "printable ASCII"),
            ('Jrn.Data "File Name", "IDOK", "{{MODEL}}"', "unknown placeholder"),
        ]
        for line, want in cases:
            lines = self.GOOD[:4] + [line] + self.GOOD[4:]
            problems = self.lint_lines(lines)
            self.assertTrue(any(want in p for p in problems), (line, problems))

    def test_structure(self):
        self.assertTrue(any("provenance" in p for p in self.lint_lines(["' hand made"] + self.GOOD[1:])))
        self.assertTrue(any("Version" in p for p in self.lint_lines(self.GOOD[:3] + self.GOOD[4:])))
        late = self.GOOD + ['Jrn.Data "File Name", "IDOK", "C:\\revit-smoke\\out\\a.rvt"']
        self.assertTrue(any("ID_APP_EXIT" in p for p in self.lint_lines(late)))
        r = run("lint", self.write("bad.txt", "\n".join(self.GOOD[1:]) + "\n"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("bad.txt:1:", r.stdout)


class Verdict(Tmp):
    TPL = "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\English\\Default-Multi-Discipline_Metric.rte"

    def setUp(self):
        super().setUp()
        self.marker = self.write("marker", "")
        old = time.time() - 30
        os.utime(self.marker, (old, old))
        self.out = os.path.dirname(self.path("out", "x"))
        self.journals = {}
        for s in ("start", "core", "reopen"):
            p = self.path("clone", s + ".txt")
            sm.write_journal(sm.make_journal(s, 2027, self.TPL), p)
            self.journals[s] = p
        self.exit = sm.exit_line(self.journals["core"])

    def rvt(self, name="smoke.rvt", data=OLE + bytes(5000), age=None):
        p = self.write(os.path.join("out", name), data)
        if age is not None:
            t = os.path.getmtime(self.marker) - age
            os.utime(p, (t, t))
        return p

    def judge(self, scenario="core", lines=None, replayed=None, **kw):
        if replayed is None:
            replayed = self.write("journal.0002.txt", "\r\n".join(lines) + "\r\n") if lines is not None else ""
        return sm.verdict(scenario, self.journals[scenario], replayed, self.marker, self.out, **kw)

    def test_pass_core_and_timings(self):
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit, idle=20.0, gap=3.0))
        self.assertEqual((v["verdict"], v["kind"]), ("pass", "pass"), v)
        self.assertEqual((v["build"], v["release"]), ("20991231_0000(x64)", "2027.3"))
        self.assertEqual((v["stopped_at"], v["exit_line"]), (self.exit, self.exit))
        self.assertEqual(v["t_start_idle"], 20.0)
        self.assertEqual(v["longest_gap"], 14.0)                # licensing done at 6 s, idle at 20 s
        self.assertEqual(v["outputs"], {"smoke.rvt": {"size": 5008, "problem": None}})
        self.assertIsNone(v["dialog_id"])

    def test_tail_end_2027_and_plain_2020(self):
        for year, tail, release in ((2027, True, "2027.3"), (2020, False, "2020"), (2024, True, "2024.3")):
            lines = replay(year=year, played="start.txt", exit_at=sm.exit_line(self.journals["start"]))
            self.assertEqual(any("JOURNAL_MARKER_TAIL_END:" in x for x in lines), tail)
            v = self.judge("start", lines)
            self.assertEqual(v["verdict"], "pass", (year, v))
            self.assertEqual(v["release"], release)
            self.assertEqual(v["outputs"], {})

    def test_long_gap_alone_is_not_a_stall(self):
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit, gap=60.0))
        self.assertEqual(v["verdict"], "pass", v)
        self.assertEqual(v["longest_gap"], 60.0)

    def test_crash(self):
        v = self.judge(lines=replay(exit_at=self.exit, strong="Unrecoverable error", finished=False))
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "crash"), v)
        self.assertIn("unrecoverable error", v["reason"])
        v = self.judge(lines=replay(exit_at=self.exit, upto="playback"))   # the journal just ends
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "crash"), v)
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit, strong="Exception occurred"))   # even if it ended well
        self.assertEqual(v["kind"], "crash", v)

    def test_crash_report_dialog_is_not_the_cause(self):
        lines = replay(exit_at=self.exit, strong="An unrecoverable error", finished=False, upto="playback",
                       dialog=("An unrecoverable error has occurred.", "TaskDialog_Unrecoverable_Error"))
        v = self.judge(lines=lines)
        self.assertEqual(v["kind"], "crash", v)
        self.assertIsNone(v["dialog_id"])

    def test_stopped_at_a_dialog(self):
        save = ("Do you want to save changes?", "TaskDialog_Save_File")
        lines = replay(exit_at=self.exit, upto="playback", dialog=save)
        v = self.judge(lines=lines, watchdog="stall")
        self.assertEqual((v["verdict"], v["kind"], v["dialog_id"]), ("fail", "dialog", "TaskDialog_Save_File"), v)
        self.assertIn("TaskDialog_Save_File", v["reason"])
        self.assertNotIn("save changes", json.dumps(v))           # the dialog text never leaves
        v = self.judge(lines=replay(exit_at=self.exit, modal_open=True), watchdog="stall")
        self.assertEqual((v["kind"], v["dialog_id"]), ("dialog", "Dialog_Revit_NewProject"), v)
        recover = ("Revit crashed last time. Recover?", "TaskDialog_Rec")
        lines = replay(exit_at=self.exit, upto="playback", dialog=recover)
        self.assertEqual(self.judge(lines=lines, watchdog="stall")["dialog_id"], "TaskDialog_Rec")

    def test_answered_dialog_passes(self):
        self.rvt()
        save = ("Do you want to save changes?", "TaskDialog_Save_File")
        lines = replay(exit_at=self.exit, dialog=save, answered=True)
        self.assertEqual(self.judge(lines=lines)["verdict"], "pass")

    def test_hung(self):
        v = self.judge(lines=replay(exit_at=self.exit, upto="idle"), watchdog="start")
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "hung_start"), v)
        v = self.judge(lines=replay(exit_at=self.exit, upto="playback"), watchdog="stall")
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "hung"), v)
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit), watchdog="total")   # killed: never a pass
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "timeout"), v)

    def test_no_output_stale_empty_and_not_ole(self):
        lines = replay(exit_at=self.exit)
        v = self.judge(lines=lines)
        self.assertEqual((v["verdict"], v["kind"], v["reason"]), ("fail", "no_output", "smoke.rvt: missing"), v)
        self.rvt(age=100)
        self.assertEqual(self.judge(lines=lines)["outputs"]["smoke.rvt"]["problem"], "stale")
        self.rvt(data=b"")
        self.assertEqual(self.judge(lines=lines)["outputs"]["smoke.rvt"]["problem"], "empty")
        self.rvt(data=b"PK\x03\x04" + bytes(100))
        self.assertEqual(self.judge(lines=lines)["reason"], "smoke.rvt: not a Revit file")

    def test_reopen_wants_smoke2(self):
        lines = replay(played="reopen.txt", exit_at=sm.exit_line(self.journals["reopen"]))
        self.rvt("smoke.rvt")
        self.assertEqual(self.judge("reopen", lines)["reason"], "smoke2.rvt: missing")
        self.rvt("smoke2.rvt")
        self.assertEqual(self.judge("reopen", lines)["verdict"], "pass")

    def test_replay_did_not_reach_the_exit(self):
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit, stop=self.exit - 3))
        self.assertEqual((v["verdict"], v["kind"]), ("fail", "incomplete"), v)
        self.assertIn(f"line {self.exit - 3}", v["reason"])

    def test_no_journal_old_journal_other_journal(self):
        self.rvt()
        for replayed in ("", "-", "--", self.path("missing.txt")):
            v = self.judge(replayed=replayed)
            self.assertEqual((v["verdict"], v["kind"]), ("fail", "no_journal"), (replayed, v))
        old = self.write("journal.0001.txt", "\r\n".join(replay(exit_at=self.exit)))
        t = os.path.getmtime(self.marker) - 100
        os.utime(old, (t, t))
        self.assertEqual(self.judge(replayed=old)["kind"], "no_journal")
        v = self.judge(lines=replay(exit_at=self.exit, played="other.txt"))
        self.assertEqual(v["kind"], "other_journal", v)
        crash = self.write("stdout.txt", "wine: Unhandled page fault on read access to 0000000000000000\n")
        self.assertIn("wine", self.judge(replayed="", crash_log=crash)["reason"])

    def test_person(self):
        v = self.judge(replayed="", no_start=True)
        self.assertEqual((v["verdict"], v["kind"]), ("person", "no_start"), v)
        self.assertTrue(v["fix"])
        v = self.judge(lines=replay(exit_at=self.exit, upto="licensing", update=False), signin_seen=True)
        self.assertEqual((v["verdict"], v["kind"]), ("person", "signin"), v)
        v = self.judge(lines=replay(exit_at=self.exit, upto="licensing", update=False), watchdog="start")
        self.assertEqual((v["verdict"], v["kind"]), ("person", "license_blocked"), v)
        for text, did in (("Your trial has ended.", "TaskDialog_Generic_Message"),
                          ("Something about the account.", "TaskDialog_License_Expired")):
            lines = replay(exit_at=self.exit, upto="playback", dialog=(text, did))
            v = self.judge(lines=lines, watchdog="stall")
            self.assertEqual((v["verdict"], v["kind"], v["dialog_id"]), ("person", "license_dialog", did), v)

    def test_signin_process_with_license_update_is_fine(self):
        self.rvt()
        v = self.judge(lines=replay(exit_at=self.exit), signin_seen=True)
        self.assertEqual(v["verdict"], "pass", v)

    def test_cli_json_without_personal_values(self):
        self.rvt()
        rep = self.write("journal.0003.txt", "\r\n".join(replay(exit_at=self.exit)) + "\r\n")
        r = run("verdict", "core", "--journal", self.journals["core"], "--replayed", rep, "--since", self.marker,
                "--outputs", self.out, "--watchdog", "none")
        self.assertEqual(r.returncode, 0, r.stderr)
        v = json.loads(r.stdout)
        self.assertEqual(v["verdict"], "pass", v)
        self.assertNotIn(USER, r.stdout)
        self.assertNotIn(self.d, r.stdout)
        for k in ("verdict", "reason", "dialog_id", "build", "release", "t_start_idle", "t_total", "longest_gap",
                  "outputs"):
            self.assertIn(k, v)
        r = run("verdict", "core", "--journal", self.journals["core"], "--replayed", "--", "--since", self.marker,
                "--outputs", self.out, "--signin-seen")
        self.assertEqual(json.loads(r.stdout)["kind"], "signin", r.stdout + r.stderr)
        self.assertNotEqual(run("verdict", "core", "--journal", self.journals["core"], "--since", self.marker,
                                "--watchdog", "maybe").returncode, 0)


class Template(Tmp):
    def ini(self, year, text, bom=True):
        p = self.path("clone", "drive_c", "users", "crossover", "AppData", "Roaming", "Autodesk", "Revit",
                      f"Autodesk Revit {year}", "Revit.ini")
        with open(p, "wb") as f:
            f.write((b"\xff\xfe" if bom else b"") + text.replace("\n", "\r\n").encode("utf-16-le"))

    def rte(self, winpath):
        parts = winpath[3:].split("\\")
        self.write(os.path.join("clone", "drive_c", *parts), b"template")

    def clone(self):
        return os.path.join(self.d, "clone")

    def test_first_existing_entry_of_revit_ini(self):
        base = "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\"
        self.ini(2027, "[Language]\nSelect=ENU\n[DirectoriesENU]\nDefaultTemplate=Imperial Multi-discipline="
                 f"{base}English-Imperial\\Default-Multi-discipline.rte, Metric Multi-discipline="
                 f"{base}English\\Default-Multi-Discipline_Metric.rte\n")
        self.rte(base + "English\\Default-Multi-Discipline_Metric.rte")
        self.assertEqual(sm.find_template(self.clone(), 2027),
                         (base + "English\\Default-Multi-Discipline_Metric.rte", "revit.ini"))
        self.rte(base + "English-Imperial\\Default-Multi-discipline.rte")
        r = run("template", self.clone(), "2027")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, base + "English-Imperial\\Default-Multi-discipline.rte\trevit.ini\n")

    def test_language_select_and_variable(self):
        label = "\u0410\u0440\u0445\u0438\u0442\u0435\u043a\u0442\u0443\u0440\u043d\u044b\u0439"   # Russian label
        self.ini(2025, "[DirectoriesENU]\nDefaultTemplate=Metric=C:\\ProgramData\\Autodesk\\RVT 2025\\Templates\\"
                 "English\\DefaultMetric.rte\n[Language]\nSelect=RUS\n[DirectoriesRUS]\n"
                 f"DefaultTemplate={label}=$AllUsersAppData\\Templates\\Russian\\DefaultRUS.rte\n", bom=False)
        self.rte("C:\\ProgramData\\Autodesk\\RVT 2025\\Templates\\English\\DefaultMetric.rte")
        self.rte("C:\\ProgramData\\Autodesk\\RVT 2025\\Templates\\Russian\\DefaultRUS.rte")
        self.assertEqual(sm.find_template(self.clone(), 2025),
                         ("C:\\ProgramData\\Autodesk\\RVT 2025\\Templates\\Russian\\DefaultRUS.rte", "revit.ini"))

    def test_table_and_none(self):
        for year, rel in ((2020, "US Imperial\\default.rte"), (2023, "English\\DefaultMetric.rte"),
                          (2026, "English\\Default-Multi-Discipline_Metric.rte")):
            p = f"C:\\ProgramData\\Autodesk\\RVT {year}\\Templates\\{rel}"
            self.assertEqual(sm.find_template(self.clone(), year), (None, None))
            self.rte(p)
            self.assertEqual(sm.find_template(self.clone(), year), (p, "table"), year)
        self.ini(2024, "[DirectoriesENU]\nDefaultTemplate=Gone=C:\\nowhere\\x.rte, Odd=C:\\ProgramData\\a\"b.rte\n")
        self.write(os.path.join("clone", "drive_c", "ProgramData", 'a"b.rte'), b"x")
        r = run("template", self.clone(), "2024")
        self.assertEqual((r.returncode, r.stdout), (1, ""))
        self.assertIn("no Revit 2024 project template", r.stderr)

    def test_names_match_without_case(self):
        self.write(os.path.join("clone", "drive_c", "programdata", "autodesk", "RVT 2027", "templates", "english",
                                "default-multi-discipline_metric.rte"), b"x")
        p = "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\English\\Default-Multi-Discipline_Metric.rte"
        self.assertTrue(sm.win_file(self.clone(), p))
        self.assertIsNone(sm.win_file(self.clone(), "D:\\x.rte"))
        self.assertIsNone(sm.win_file(self.clone(), "C:\\ProgramData\\..\\..\\x.rte"))


class Signin(Tmp):
    def journal(self, n, lines, age_days):
        d = os.path.join(self.d, "b", "drive_c", "users", "crossover", "AppData", "Local", "Autodesk", "Revit",
                         "Autodesk Revit 2027", "Journals")
        p = self.write(os.path.join(d, f"journal.{n:04d}.txt"), "\r\n".join(lines) + "\r\n")
        t = time.time() - age_days * 86400 - 60
        os.utime(p, (t, t))
        return p

    def test_signed_in_age_and_days_left(self):
        self.journal(1, ["' 0:< License mode: User", "' 0:< Status: Your license will expire in 300 days."], 90)
        self.journal(2, ["' 0:< License mode: User", "' 0:< Status: Your license will expire in 5 days.",
                         f'        "Username"  , "{USER}"'], 40)
        r = run("signin", os.path.join(self.d, "b"), "2027")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), {"signed_in": True, "journal_age_days": 40, "license_days_left": 5})
        self.assertNotIn(USER, r.stdout)

    def test_not_signed_in(self):
        self.journal(3, ["' 0:< License mode: User"], 10)
        self.journal(4, ["' 0:< manage licensing"], 0)
        self.assertEqual(sm.signin(os.path.join(self.d, "b"), 2027),
                         {"signed_in": False, "journal_age_days": 0, "license_days_left": None})
        self.assertEqual(sm.signin(os.path.join(self.d, "none"), 2027),
                         {"signed_in": False, "journal_age_days": None, "license_days_left": None})


if __name__ == "__main__":
    unittest.main()
