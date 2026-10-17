# SPDX-License-Identifier: MIT
"""Unit tests for tools/runlog.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here: synthetic bottles, summaries and databases."""
import hashlib, importlib.util, json, os, stat, subprocess, sys, tempfile, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rl = load("runlog")
FIELDS = ["run_id", "time", "kind", "year", "requested", "done", "skipped", "failed", "result", "engine", "crossover",
          "compatdb_sha256", "shims", "revit_build_expected", "extracted"]


def run(*args):
    return subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "runlog.py"), *args],
                          capture_output=True, text=True)


def line(step, code, text="(1 s)"):
    return "   %-10s exit=%-5s %s\n" % (step, code, text)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.bottle = os.path.join(self.d, "Bottles", "rvt2027-t")
        os.makedirs(os.path.join(self.bottle, "drive_c"))
        with open(os.path.join(self.bottle, "cxbottle.conf"), "w") as f:
            f.write('[Bottle]\n"Description" = "Revit 2027"\n')
        self.run_dir = os.path.join(self.d, "logs", "rvt2027-t", "20261016-111128-install")
        os.makedirs(self.run_dir)

    def tearDown(self):
        for root, dirs, _ in os.walk(self.d):
            for n in dirs:
                os.chmod(os.path.join(root, n), 0o755)
        self.tmp.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.run_dir, name), "w") as f:
            f.write(text)

    def runs(self):
        with open(rl.runs_file(self.bottle)) as f:
            return [json.loads(x) for x in f.read().splitlines()]

    def append(self, *extra, result="ok", kind="install", requested="vc fonts rvt"):
        return run("append", self.bottle, "--kind", kind, "--year", "2027", "--run-id", "r1", "--result", result,
                   "--requested", requested, "--run-dir", self.run_dir, *extra)


class Steps(Tmp):
    def test_summary_lines_of_the_requested_steps(self):
        # action lines of install.sh and the parts a step writes itself are not steps that were asked for
        self.write("summary.txt", line("shims", 0, "scripts/get-shims.sh (3 s; action-shims.log)") + line("vc22x64", 0)
                   + line("vc", 0) + line("fonts", "skip", "not needed") + line("licensing", 85, "see ~/x.log")
                   + line("revitlookup", 0) + line("steps", 1) + "continued text exit=0\n")
        done, skipped, failed = rl.steps_of(self.run_dir, ["vc", "fonts", "licensing", "rvt", "revitlookup"])
        self.assertEqual(done, ["vc", "revitlookup"])
        self.assertEqual(skipped, ["fonts"])
        self.assertEqual(failed, ["licensing"])

    def test_the_last_line_of_a_step_counts_and_failed_txt_adds(self):
        self.write("summary.txt", line("rvt", 1) + line("rvt", 0) + line("tlbpin", 0) + line("pkgs", 0))
        self.write("failed.txt", "tlbpin\nwv2fix\n")
        done, skipped, failed = rl.steps_of(self.run_dir, ["rvt", "pkgs", "tlbpin", "wv2fix"])
        self.assertEqual(done, ["rvt", "pkgs"])
        self.assertEqual(failed, ["tlbpin", "wv2fix"])
        self.assertEqual(skipped, [])

    def test_no_run_folder_or_no_summary(self):
        self.assertEqual(rl.steps_of("", ["vc"]), ([], [], []))
        self.assertEqual(rl.steps_of(os.path.join(self.d, "none"), ["vc"]), ([], [], []))


class Append(Tmp):
    def test_one_json_line_with_every_field(self):
        self.write("summary.txt", line("vc", 0) + line("fonts", "skip") + line("rvt", 67))
        self.write("failed.txt", "rvt\n")
        db = os.path.join(self.d, "compatdb-26.dat")
        with open(db, "wb") as f:
            f.write(b"compat\0rules" * 100)
        r = self.append("--engine", "git:16b7a92+dirty", "--crossover", "26.3.0.39832", "--compatdb", db,
                        "--shims", "0.6.0", "--build", "27.3.0.28", result="partial")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout + r.stderr, "")
        recs = self.runs()
        self.assertEqual(len(recs), 1)
        rec = recs[0]
        self.assertEqual(list(rec), FIELDS)
        self.assertRegex(rec["time"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual((rec["run_id"], rec["kind"], rec["year"], rec["result"]), ("r1", "install", 2027, "partial"))
        self.assertEqual((rec["requested"], rec["done"], rec["skipped"], rec["failed"]),
                         (["vc", "fonts", "rvt"], ["vc"], ["fonts"], ["rvt"]))
        self.assertEqual(rec["compatdb_sha256"], hashlib.sha256(b"compat\0rules" * 100).hexdigest())
        self.assertEqual((rec["engine"], rec["crossover"], rec["shims"], rec["revit_build_expected"]),
                         ("git:16b7a92+dirty", "26.3.0.39832", "0.6.0", "27.3.0.28"))

    def test_unknown_values(self):
        r = self.append("--compatdb", os.path.join(self.d, "compatdb-none.dat"), "--crossover", "", "--build", "")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.runs()[0]
        self.assertIsNone(rec["compatdb_sha256"])
        self.assertIsNone(rec["crossover"])
        self.assertIsNone(rec["revit_build_expected"])
        self.assertEqual((rec["engine"], rec["shims"]), ("unknown", "unknown"))
        self.assertIsNone(rec["extracted"])

    def test_extracted_is_the_real_path(self):
        os.makedirs(os.path.join(self.d, "data", "installers", "extracted", "revit2027"))
        os.symlink(os.path.join(self.d, "data"), os.path.join(self.d, "link"))
        r = self.append("--extracted", os.path.join(self.d, "link", "installers", "extracted", "revit2027"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.runs()[0]["extracted"],
                         os.path.realpath(os.path.join(self.d, "data", "installers", "extracted", "revit2027")))

    def test_appends_and_keeps_older_lines(self):
        self.append(result="failed")
        self.append(kind="addins", requested="revitlookup check", result="stopped")
        with open(rl.runs_file(self.bottle), "rb") as f:
            raw = f.read()
        self.assertEqual(raw.count(b"\n"), 2)
        self.assertTrue(raw.endswith(b"\n"))
        self.assertEqual([x["result"] for x in self.runs()], ["failed", "stopped"])

    def test_no_bottle_no_folder(self):
        for target in (os.path.join(self.d, "Bottles", "gone"), os.path.join(self.d, "Bottles", "half")):
            if target.endswith("half"):
                os.makedirs(os.path.join(target, "drive_c"))   # a folder without cxbottle.conf is not a bottle
            r = run("append", target, "--kind", "install", "--year", "2027", "--run-id", "r", "--result", "failed",
                    "--requested", "vc")
            self.assertEqual(r.returncode, 1)
            self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
            self.assertIn("cxbottle.conf", r.stderr)
            self.assertFalse(os.path.exists(os.path.join(target, "revit-macos")))
        self.assertFalse(os.path.exists(os.path.join(self.d, "Bottles", "gone")))

    @unittest.skipIf(os.geteuid() == 0, "root writes anywhere")
    def test_unwritable_folder_is_one_line_and_exit_1(self):
        os.makedirs(os.path.join(self.bottle, "revit-macos"))
        os.chmod(os.path.join(self.bottle, "revit-macos"), stat.S_IRUSR | stat.S_IXUSR)
        r = self.append()
        self.assertEqual(r.returncode, 1)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
        self.assertIn("runs.ndjson", r.stderr)

    def test_bad_arguments(self):
        self.assertEqual(self.append(result="busy").returncode, 2)
        self.assertEqual(self.append(kind="debug").returncode, 2)
        self.assertEqual(run().returncode, 2)
        self.assertFalse(os.path.exists(rl.runs_file(self.bottle)))


class Last(Tmp):
    def test_newest_of_a_kind(self):
        self.append(result="ok")
        self.append(kind="addins", requested="check", result="partial")
        r = run("last", self.bottle)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["kind"], "addins")
        r = run("last", self.bottle, "--kind", "install")
        self.assertEqual(json.loads(r.stdout)["result"], "ok")
        self.assertEqual(run("last", self.bottle, "--kind", "steps").returncode, 1)

    def test_nothing_and_broken_lines(self):
        r = run("last", self.bottle)
        self.assertEqual((r.returncode, r.stdout), (1, ""))
        self.append(result="failed")
        with open(rl.runs_file(self.bottle), "a") as f:
            f.write('{"run_id": "cut sh\n[1, 2]\n\n')
        self.assertEqual(rl.last(self.bottle)["result"], "failed")
        self.assertEqual(len(rl.records(self.bottle)), 1)

    def test_last_writes_nothing(self):
        before = sorted(os.listdir(self.bottle))
        run("last", self.bottle)
        self.assertEqual(sorted(os.listdir(self.bottle)), before)


class Uses(Tmp):
    def folder(self, name):
        p = os.path.join(self.d, name, "installers", "extracted", "revit2027")
        os.makedirs(p, exist_ok=True)
        return p

    def uses(self, folder):
        return run("uses", self.bottle, folder).returncode

    def test_the_folder_its_records_name(self):
        app, clone = self.folder("app"), self.folder("clone")
        self.append("--extracted", clone)
        self.append(kind="addins", requested="check")   # read no unpacked folder
        self.assertEqual(self.uses(clone), 0)
        self.assertEqual(self.uses(app), 1)
        self.append("--extracted", app)
        self.assertEqual(self.uses(app), 0)

    def test_unknown_means_it_may(self):
        app = self.folder("app")
        self.assertEqual(self.uses(app), 0)   # no record
        self.append("--extracted", self.folder("clone"))
        with open(rl.runs_file(self.bottle), "a") as f:
            f.write('{"run_id":"old","kind":"install","year":2027,"result":"ok"}\n')   # from before the field
        self.assertEqual(self.uses(app), 0)

    def test_only_addin_runs_say_nothing_about_the_install(self):
        self.append(kind="addins", requested="check")
        self.assertEqual(self.uses(self.folder("app")), 0)

    def test_a_line_that_is_not_a_record_means_it_may(self):
        app = self.folder("app")
        self.append("--extracted", self.folder("clone"))
        with open(rl.runs_file(self.bottle), "a") as f:
            f.write('{"run_id":"cut sh\n')
        self.assertEqual(self.uses(app), 0)

    def test_the_same_folder_spelled_another_way(self):
        clone = self.folder("clone")
        self.append("--extracted", clone)
        self.assertEqual(self.uses(clone + "/"), 0)
        upper = os.path.join(self.d, "CLONE", "installers", "extracted", "revit2027")
        if os.path.isdir(upper):   # a volume that ignores case (APFS by default)
            self.assertEqual(self.uses(upper), 0)

    def test_bad_arguments(self):
        self.assertEqual(run("uses", self.bottle).returncode, 2)


if __name__ == "__main__":
    unittest.main()
