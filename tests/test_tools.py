# SPDX-License-Identifier: MIT
"""Unit tests for the Python helpers in tools/. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; nothing from Autodesk or Microsoft is needed."""
import importlib.util, io, os, struct, subprocess, sys, tempfile, unittest, zipfile

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(tool, *args):
    return subprocess.run([sys.executable, "-I", os.path.join(TOOLS, tool + ".py"), *args],
                          capture_output=True, text=True)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.d, name)


class PeMark(Tmp):
    def test_replaces_marker(self):
        src = self.path("in.dll")
        open(src, "wb").write(b"MZ" + bytes(62) + b"Wine builtin DLL" + bytes(64))
        r = run("pe_mark", src, self.path("out.dll"), "DXVK native  DLL")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(b"DXVK native  DLL", open(self.path("out.dll"), "rb").read())

    def test_refuses_file_without_marker(self):
        src = self.path("in.dll")
        open(src, "wb").write(b"MZ" + bytes(200))
        self.assertNotEqual(run("pe_mark", src, self.path("out.dll"), "DXVK native  DLL").returncode, 0)

    def test_refuses_wrong_length(self):
        src = self.path("in.dll")
        open(src, "wb").write(b"MZ" + bytes(62) + b"Wine builtin DLL")
        self.assertNotEqual(run("pe_mark", src, self.path("out.dll"), "short").returncode, 0)


class BottleEnv(Tmp):
    def conf(self, text):
        p = self.path("cxbottle.conf")
        open(p, "w").write(text)
        return p

    def test_set_change_remove(self):
        p = self.conf('[Bottle]\n"Description" = "Revit 2024"\n\n[EnvironmentVariables]\n"A" = "1"\n\n[Other]\n"X" = "y"\n')
        self.assertEqual(run("bottle_env", p, "A=2", "B=two words").returncode, 0)
        text = open(p).read()
        self.assertIn('"A" = "2"', text)
        self.assertIn('"B" = "two words"', text)
        self.assertIn('[Other]\n"X" = "y"', text)
        self.assertEqual(run("bottle_env", p, "-A").returncode, 0)
        self.assertNotIn('"A" =', open(p).read())

    def test_adds_missing_section(self):
        p = self.conf('[Bottle]\n"Description" = "Revit 2024"\n')
        self.assertEqual(run("bottle_env", p, "A=1").returncode, 0)
        self.assertIn('[EnvironmentVariables]\n"A" = "1"', open(p).read())

    def test_escapes_quotes_and_backslashes(self):
        p = self.conf("[EnvironmentVariables]\n")
        run("bottle_env", p, 'A=say "hi" C:\\x')
        self.assertIn('"A" = "say \\"hi\\" C:\\\\x"', open(p).read())

    def test_rerun_is_stable(self):
        p = self.conf("[EnvironmentVariables]\n")
        run("bottle_env", p, "A=1")
        first = open(p).read()
        run("bottle_env", p, "A=1")
        self.assertEqual(first, open(p).read())


class RevitIni(Tmp):
    def ini(self, lines, bom=True):
        p = self.path("Revit.ini")
        open(p, "wb").write(("\ufeff" if bom else "").encode("utf-16-le") + "\r\n".join(lines).encode("utf-16-le"))
        return p

    def read(self, p):
        return open(p, "rb").read().decode("utf-16").split("\r\n")

    def test_sets_and_adds_keeps_bom_and_orig(self):
        p = self.ini(["[Language]", "Select=en-US", "", "[Graphics]", "Antialiasing=1", ""])
        r = run("revitini", p, "Language.Select=ENU", "AppFrame.Theme=0")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = self.read(p)
        self.assertIn("Select=ENU", lines)
        self.assertIn("[AppFrame]", lines)
        self.assertTrue(open(p, "rb").read().startswith(b"\xff\xfe"))
        self.assertTrue(os.path.exists(p + ".orig"))

    def test_rerun_keeps_other_changes(self):
        p = self.ini(["[Language]", "Select=en-US", ""])
        run("revitini", p, "Language.Select=ENU")
        lines = self.read(p) + ["[Directories]", "ProjectPath=C:\\mine", ""]   # the user changes Options
        open(p, "wb").write(b"\xff\xfe" + "\r\n".join(lines).encode("utf-16-le"))
        run("revitini", p, "Language.Select=ENU")
        self.assertIn("ProjectPath=C:\\mine", self.read(p))
        self.assertNotIn("ProjectPath=C:\\mine", open(p + ".orig", "rb").read().decode("utf-16"))


class DynamoSettings(Tmp):
    def test_creates_and_updates(self):
        p = self.path("DynamoSettings.xml")
        self.assertEqual(run("dynamo_settings", p).returncode, 0)
        text = open(p).read()
        self.assertIn("<UseHardwareAcceleration>false</UseHardwareAcceleration>", text)
        self.assertIn("<IsFirstRun>false</IsFirstRun>", text)
        self.assertEqual(run("dynamo_settings", p).returncode, 0)
        self.assertEqual(open(p).read().count("IsRevitBackgroundPreviewActive"), 1)


class Odis(Tmp):
    def test_list_and_get(self):
        os.makedirs(self.path("manifest"))
        os.makedirs(self.path("x64/A"))
        open(self.path("manifest/app.RVT.xml"), "w").write(
            '<Packages><Package name="A" installAs="x" path="x64/A/pkg.A.xml"/></Packages>')
        open(self.path("x64/A/pkg.A.xml"), "w").write(
            '<Package><InstallFile type="MSI" file="x64/A/A.msi" installParams="P=1 &amp; Q"/></Package>')
        r = run("odis", "get", self.d, "A")
        self.assertEqual(r.stdout.strip().split("\t"), ["A", "x", "MSI", "x64/A/A.msi", "P=1 & Q"])
        self.assertNotEqual(run("odis", "get", self.d, "B").returncode, 0)
        self.assertNotEqual(run("odis", "frobnicate", self.d).returncode, 0)


class Adix(Tmp):
    def adix(self, names):
        p = self.path("p.adix")
        with zipfile.ZipFile(p, "w") as z:
            for n in names:
                z.writestr(n, b"x")
        return p

    def test_files_into_drive_c(self):
        drive = self.path("drive_c")
        r = run("adix", "files", self.adix(["VFS/ProgramFilesX64/Autodesk/a.txt", "AppxManifest.xml"]), drive)
        self.assertEqual(r.stdout.strip(), "1")
        self.assertTrue(os.path.exists(os.path.join(drive, "Program Files/Autodesk/a.txt")))

    def test_refuses_dotdot(self):
        r = run("adix", "files", self.adix(["VFS/ProgramFilesX64/../../evil.txt"]), self.path("drive_c"))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.path("evil.txt")))


class WinShortcut(Tmp):
    def test_info(self):
        lnk = bytearray(b"\x4c\x00\x00\x00" + bytes(16))
        lnk += struct.pack("<I", 0x20 | 0x40 | 0x80)    # has arguments, icon, unicode
        lnk += bytes(76 - len(lnk))
        for s in ("/viewer /language ENU", "C:\\Revit.ico"):
            lnk += struct.pack("<H", len(s)) + s.encode("utf-16-le")
        p = self.path("Revit.lnk")
        open(p, "wb").write(bytes(lnk))
        r = run("win_shortcut", "info", p)
        self.assertEqual(r.stdout.rstrip("\n").split("\t"), ["", "/viewer /language ENU", "C:\\Revit.ico"])


class GenForwards(Tmp):
    GEN = os.path.join(TOOLS, "shims", "ncryptshim", "gen_forwards.py")

    def test_writes_the_three_files(self):
        open(self.path("exports.txt"), "w").write("NCryptImportKey\nNCryptDeleteKey\nBCryptEncrypt\n")
        r = subprocess.run([sys.executable, "-I", self.GEN, self.path("exports.txt"), self.path("gen")],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("forwards=1 bcrypt-forwarders=1", r.stdout)
        self.assertIn("jmp *__real_NCryptDeleteKey(%rip)", open(self.path("gen/forwards.S")).read())
        d = open(self.path("gen/ncrypt.def")).read()
        self.assertIn("    NCryptImportKey\n", d)
        self.assertIn("    BCryptEncrypt = bcrypt.BCryptEncrypt", d)

    def test_missing_exports_file(self):
        r = subprocess.run([sys.executable, "-I", self.GEN, self.path("none.txt"), self.path("gen")],
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("gen_forwards:", r.stderr)


if __name__ == "__main__":
    unittest.main()
