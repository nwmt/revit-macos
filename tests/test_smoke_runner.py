# SPDX-License-Identifier: MIT
"""Unit tests for the runner side of tools/smoke.py: clone-conf, conf-get, replayed, result and summary (what
scripts/smoke.sh asks of it). Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every file is generated here."""
import importlib.util, json, os, stat, subprocess, sys, tempfile, time, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sm = load("smoke")
JOURNALS = "drive_c/users/crossover/AppData/Local/Autodesk/Revit/Autodesk Revit {}/Journals"


def run(*args):
    return subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "smoke.py"), *args],
                          capture_output=True, text=True)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel, data, mtime=None):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def read(self, rel):
        with open(os.path.join(self.d, rel), "rb") as f:
            return f.read().decode("utf-8")


class CloneConf(Tmp):
    CONF = ('[Bottle]\r\n;;"BottleID" = ""\r\n"Version" = "26.3.0.39832"\r\n"menumode" = "install"\r\n'
            '"Description" = "Revit 2027"\r\n\r\n[EnvironmentVariables]\r\n"MenuMode" = "keep me"\r\n')

    def test_sets_the_three_keys_and_keeps_the_rest(self):
        p = self.write("cxbottle.conf", self.CONF)
        os.chmod(p, 0o640)
        sm.clone_conf(p, "ABC-123")
        text = self.read("cxbottle.conf")
        self.assertEqual(text, '[Bottle]\r\n"BottleID" = "ABC-123"\r\n"Version" = "26.3.0.39832"\r\n'
                               '"MenuMode" = "ignore"\r\n"Description" = "Revit 2027"\r\n"AssocMode" = "ignore"\r\n'
                               '\r\n[EnvironmentVariables]\r\n"MenuMode" = "keep me"\r\n')
        self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o640)
        self.assertEqual(sorted(os.listdir(self.d)), ["cxbottle.conf"])   # no temporary file left

    def test_lf_file_and_a_key_set_twice(self):
        p = self.write("c.conf", '[Bottle]\n"BottleID" = "OLD"\n"AssocMode" = "install"\n"BottleID" = "OLD2"\n')
        sm.clone_conf(p, "NEW")
        self.assertEqual(self.read("c.conf"), '[Bottle]\n"BottleID" = "NEW"\n"AssocMode" = "ignore"\n'
                                              '"BottleID" = "NEW"\n"MenuMode" = "ignore"\n')

    def test_a_conf_without_bottle_section_is_refused(self):
        p = self.write("c.conf", '[EnvironmentVariables]\n"A" = "b"\n')
        with self.assertRaises(SystemExit):
            sm.clone_conf(p, "NEW")
        self.assertEqual(self.read("c.conf"), '[EnvironmentVariables]\n"A" = "b"\n')

    def test_cli_makes_a_bottle_id_or_checks_the_given_one(self):
        p = self.write("c.conf", '[Bottle]\n"BottleID" = "OLD"\n')
        r = run("clone-conf", p)
        self.assertEqual(r.returncode, 0, r.stderr)
        bid = sm.conf_get(p, "bottle", "bottleid")
        self.assertRegex(bid, r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
        self.assertNotEqual(run("clone-conf", p, "--uuid", "a b").returncode, 0)
        self.assertEqual(sm.conf_get(p, "Bottle", "BottleID"), bid)


class ConfGet(Tmp):
    def test_names_without_case(self):
        p = self.write("CrossOver.conf",
                       '[CrossOver]\n;; BuildTimestamp  a comment\n"BuildTimestamp" = "20260715T103801Z"\n')
        self.assertEqual(sm.conf_get(p, "crossover", "buildtimestamp"), "20260715T103801Z")
        r = run("conf-get", p, "CrossOver", "BuildTimestamp")
        self.assertEqual((r.returncode, r.stdout), (0, "20260715T103801Z\n"))
        self.assertEqual(run("conf-get", p, "Bottle", "Timestamp").returncode, 1)
        self.assertEqual(run("conf-get", os.path.join(self.d, "none"), "a", "b").returncode, 1)


class Replayed(Tmp):
    def test_working_folder_first_then_appdata_and_only_new_ones(self):
        now = time.time()
        since = self.write("since", "", mtime=now - 10)
        self.write(JOURNALS.format(2025) + "/journal.0001.txt", "old\n", mtime=now - 100)
        self.assertIsNone(sm.replayed(self.d, 2025, os.stat(since).st_mtime_ns))
        a = self.write(JOURNALS.format(2025) + "/journal.0002.txt", "x\r\n' 0:< appPriv idle \r\n", mtime=now - 5)
        self.assertEqual(sm.replayed(self.d, 2025, os.stat(since).st_mtime_ns), (a, os.path.getsize(a), True))
        w = self.write("drive_c/revit-smoke/journal.0001.txt", "still starting\n", mtime=now - 1)
        self.write("drive_c/revit-smoke/journal.txt", "not a journal name\n", mtime=now)
        self.assertEqual(sm.replayed(self.d, 2025, os.stat(since).st_mtime_ns), (w, 15, False))
        r = run("replayed", self.d, "2025", "--since", since)
        self.assertEqual((r.returncode, r.stdout), (0, f"{w}\t15\t0\n"))

    def test_none_is_exit_1(self):
        since = self.write("since", "")
        self.assertEqual(run("replayed", self.d, "2027", "--since", since).returncode, 1)


VERDICT_PASS = {"verdict": "pass", "kind": "pass", "reason": "Revit played the journal to its end and quit normally",
                "fix": None, "dialog_id": None, "build": "20991231_0000(x64)", "release": "2027.3", "stopped_at": 11,
                "exit_line": 11, "t_start_idle": 16.0, "t_total": 31.5, "longest_gap": 3.0, "outputs": {}}


class Result(Tmp):
    def state(self, meta, verdicts=None, runs=None):
        st = tempfile.mkdtemp(dir=self.d)
        base = {"run_id": "r1", "time": "2026-10-16T11:11:28Z", "year": "2027", "bottle": "rvt2027-a",
                "copy": "rvt2027-a.test", "crossover": "26.3.0.39832", "engine": "git:abc1234",
                "scenarios": "start core reopen", "prepare": "ok", "upgraded": "0", "prepare_seconds": "4",
                "copy_removed": "1"}
        base.update(meta)
        with open(os.path.join(st, "meta"), "w") as f:
            f.write("".join(f"{k}={v}\n" for k, v in base.items() if v is not None))
        for name, v in (verdicts or {}).items():
            with open(os.path.join(st, name + ".verdict.json"), "w") as f:
                json.dump(v, f)
        for name, r in (runs or {}).items():
            with open(os.path.join(st, name + ".run"), "w") as f:
                f.write("".join(f"{k}={v}\n" for k, v in r.items()))
        return st

    RUN = {"seconds": "35", "watchdog": "none", "worker_killed": "0", "signin_seen": "0", "no_start": "0"}

    def test_all_passed(self):
        st = self.state({}, {n: VERDICT_PASS for n in ("start", "core", "reopen")},
                        {n: self.RUN for n in ("start", "core", "reopen")})
        out = os.path.join(self.d, "result.json")
        r = run("result", st, "--out", out)
        self.assertEqual((r.returncode, r.stdout), (0, "ok\n"), r.stderr)
        with open(out) as f:
            res = json.load(f)
        self.assertEqual([s["result"] for s in res["scenarios"]], ["passed"] * 3)
        self.assertEqual(res["scenarios"][0]["seconds"], 35)
        self.assertEqual((res["prepare"]["ok"], res["prepare"]["upgraded"], res["copy_removed"]), (True, False, True))
        self.assertEqual(res["not_checked"], ["sign-in", "add-ins", "web panels", "how Revit looks"])

    def test_a_failure_skips_the_rest_and_a_person_has_its_own_result(self):
        fail = dict(VERDICT_PASS, verdict="fail", kind="crash", reason="Revit crashed (captureTryCrash)")
        res = sm.build_result(self.state({}, {"start": VERDICT_PASS, "core": fail},
                                         {"start": self.RUN, "core": self.RUN}))
        self.assertEqual(res["result"], "failed")
        self.assertEqual([(s["result"], s.get("reason")) for s in res["scenarios"]][1:],
                         [("failed", "Revit crashed (captureTryCrash)"), ("skipped", "core did not pass")])
        person = dict(VERDICT_PASS, verdict="person", kind="signin", reason="Revit asked to sign in", fix="Sign in.")
        res = sm.build_result(self.state({}, {"start": person}, {"start": dict(self.RUN, signin_seen="1")}))
        self.assertEqual((res["result"], res["scenarios"][0]["signin_seen"]), ("needs_person", True))

    def test_prepare_failed_stopped_and_an_error_before_the_scenarios(self):
        res = sm.build_result(self.state({"prepare": "failed", "prepare_reason": "the upgrade failed (exit 1)"}))
        self.assertEqual((res["result"], res["reason"]), ("prepare_failed", "the upgrade failed (exit 1)"))
        self.assertEqual({s["reason"] for s in res["scenarios"]}, {"the copy was not ready"})
        res = sm.build_result(self.state({"stopped": "1"}, {"start": VERDICT_PASS},
                                         {"start": self.RUN, "core": dict(self.RUN, stopped="1")}))
        self.assertEqual((res["result"], res["scenarios"][1]["result"]), ("stopped", "stopped"))
        res = sm.build_result(self.state({"prepare": None, "error": "copying the bottle failed"}))
        self.assertEqual((res["result"], res["reason"]), ("failed", "copying the bottle failed"))

    def test_a_template_of_the_user_is_not_named(self):
        ours = "C:\\ProgramData\\Autodesk\\RVT 2027\\Templates\\English\\Default-Multi-Discipline_Metric.rte"
        res = sm.build_result(self.state({"template": ours, "template_source": "table"}))
        self.assertEqual(res["template"], {"path": ours, "source": "table", "own": False})
        own = "C:\\users\\crossover\\Documents\\Acme Client\\firm.rte"
        res = sm.build_result(self.state({"template": own, "template_source": "revit.ini"}))
        self.assertEqual(res["template"], {"path": None, "source": "revit.ini", "own": True})
        self.assertNotIn("Acme", json.dumps(res))


class Summary(Tmp):
    def res(self, **kw):
        r = {"year": 2027, "bottle": "rvt2027-a", "time": "2026-10-16T11:11:28Z", "result": "ok", "reason": None,
             "scenarios": [dict(VERDICT_PASS, name="start", result="passed")]}
        r.update(kw)
        return r

    def test_table_earlier_passes_and_the_last_lines(self):
        logs = os.path.join(self.d, "logs")
        for name, year, t, total in (("a", 2027, "2026-10-01T00:00:00Z", 30), ("b", 2027, "2026-10-02T00:00:00Z", 32),
                                     ("c", 2025, "2026-10-03T00:00:00Z", 99), ("d", 2027, "2026-10-20T00:00:00Z", 77)):
            self.write(f"logs/rvt{year}-a/{name}-test/result.json", json.dumps(
                {"year": year, "time": t, "scenarios": [{"name": "start", "result": "passed", "t_start_idle": 15,
                                                         "t_total": total}]}))
        here = self.write("logs/rvt2027-a/now-test/result.json", json.dumps(self.res()))
        lines = sm.summary(self.res(), logs, here)
        self.assertEqual(lines[0],
                         "Revit 2027 in a temporary copy of rvt2027-a (release 2027.3, build 20991231_0000(x64)):")
        self.assertEqual(lines[1], "  start   passed     Revit ready in 16 s, done in 31.5 s, longest pause 3 s")
        self.assertEqual(lines[2].strip(), "earlier passes: ready in 15/15 s, done in 32/30 s")
        self.assertEqual(lines[-2:], ["Not checked: sign-in, add-ins, web panels, how Revit looks.",
                                      "To share this result: ./revit report 2027"])

    def test_failures_people_and_another_bottle(self):
        res = self.res(bottle="rvt2027-b", result="needs_person", scenarios=[
            {"name": "start", "result": "needs_person", "reason": "Revit asked to sign in", "fix": "Sign in first."},
            {"name": "core", "result": "skipped", "reason": "start did not pass"}])
        lines = sm.summary(res)
        self.assertIn("  start   needs you  Revit asked to sign in", lines)
        self.assertIn("                     Sign in first.", lines)
        self.assertIn("  core    skipped    start did not pass", lines)
        self.assertEqual(lines[-1], "To share this result: ./revit report 2027 rvt2027-b")
        lines = sm.summary(self.res(result="prepare_failed", reason="the upgrade failed (exit 1)", scenarios=[]))
        self.assertIn("  CrossOver could not prepare the copy: the upgrade failed (exit 1).", lines)


if __name__ == "__main__":
    unittest.main()
