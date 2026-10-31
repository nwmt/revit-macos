"""tools/bottle_state.py: the settings and the record of what built a bottle, from a bottle's files."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "bottle_state.py")


def reg(path, keys):
    with open(path, "w", encoding="utf-8") as f:
        f.write("WINE REGISTRY Version 2\n")
        for key, lines in keys.items():
            f.write(f"\n[{key}] 1\n" + "\n".join(lines) + "\n")


class BottleState(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.addCleanup(self.t.cleanup)
        self.b = self.t.name

    def state(self):
        r = subprocess.run([sys.executable, "-I", "-B", TOOL, self.b], capture_output=True, text=True, check=True)
        return json.loads(r.stdout)

    def regs(self, retina="y", dpi=192, cmd="y", option="y"):
        mac = [f'"RetinaMode"="{retina}"', f'"LeftCommandIsCtrl"="{cmd}"', f'"RightCommandIsCtrl"="{cmd}"', f'"LeftOptionIsAlt"="{option}"']
        reg(os.path.join(self.b, "user.reg"), {"Software\\\\Wine\\\\Mac Driver": mac,
                                               "Control Panel\\\\Desktop": [f'"LogPixels"=dword:{dpi:08x}']})
        reg(os.path.join(self.b, "system.reg"), {
            "System\\\\CurrentControlSet\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts": [f'"LogPixels"=dword:{dpi:08x}']})

    def runs(self, *records):
        os.makedirs(os.path.join(self.b, "revit-macos"))
        with open(os.path.join(self.b, "revit-macos", "runs.ndjson"), "w", encoding="utf-8") as f:
            f.write("\n".join(r if isinstance(r, str) else json.dumps(r) for r in records) + "\n")

    def test_no_files(self):
        self.assertEqual(self.state(), {"retina": "", "keys": "", "built": None})

    def test_retina(self):
        for args, want in ((("y", 192), "on"), (("y", 144), "compact"), (("n", 96), "off"), (("y", 96), "mixed"), (("n", 192), "mixed")):
            self.regs(*args)
            self.assertEqual(self.state()["retina"], want, args)

    def test_keys(self):
        self.regs()
        self.assertEqual(self.state()["keys"], "mac")
        self.regs(cmd="n", option="n")
        self.assertEqual(self.state()["keys"], "windows")
        self.regs(cmd="y", option="n")
        self.assertEqual(self.state()["keys"], "")

    def test_built_is_the_newest_good_install(self):
        good = {"kind": "install", "result": "partial", "shims": "0.15.0", "engine": "app:0.1.3", "time": "2026-10-30T21:34:22Z", "revit_build_expected": "27.3.0.1"}
        self.runs({"kind": "install", "result": "ok", "shims": "0.14.0", "engine": "x", "time": "t"}, good, "not json",
                  {"kind": "install", "result": "failed", "shims": "0.16.0", "engine": "y", "time": "t"},
                  {"kind": "addins", "result": "ok", "shims": "0.17.0", "engine": "z", "time": "t"})
        self.assertEqual(self.state()["built"], {"shims": "0.15.0", "engine": "app:0.1.3", "time": "2026-10-30T21:34:22Z", "build": "27.3.0.1"})

    def test_status_keys(self):
        self.regs()
        r = subprocess.run([sys.executable, "-I", "-B", TOOL, self.b, "--status", "works", "--tested", "2027.3", "--gaps", "G",
                            "--steps", "vc retina mackeys steel gdrive", "--theme", "", "--steel", "off",
                            "--gdrive", '{"mode": "account"}'], capture_output=True, text=True, check=True)
        d = json.loads("{" + r.stdout[1:] + "}")
        self.assertEqual(d, {"support": {"status": "works", "tested": "2027.3", "gaps": "G"}, "built": None,
                             "settings": {"retina": "on", "keys": "mac", "steel": "off", "gdrive": "account"}})

    def test_built_old_records(self):
        self.runs({"kind": "install", "result": "ok"})
        self.assertEqual(self.state()["built"], {"shims": "", "engine": "", "time": "", "build": ""})


if __name__ == "__main__":
    unittest.main()
