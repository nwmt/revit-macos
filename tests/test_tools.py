# SPDX-License-Identifier: MIT
"""Unit tests for the Python helpers in tools/. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; nothing from Autodesk or Microsoft is needed."""
import hashlib, importlib.util, io, json, os, shutil, struct, subprocess, sys, tempfile, time, unittest, zipfile

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
        self.assertIn("<EnableStaticSplashScreen>false</EnableStaticSplashScreen>", text)
        self.assertEqual(run("dynamo_settings", p).returncode, 0)
        self.assertEqual(open(p).read().count("IsRevitBackgroundPreviewActive"), 1)
        self.assertEqual(open(p).read().count("EnableStaticSplashScreen"), 2)   # one element: open and close tag


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

    def test_several_manifests_read_rvt(self):  # 2021: an app.*.xml per package, app.RVT.xml lists them all
        os.makedirs(self.path("manifest"))
        os.makedirs(self.path("x64/A"))
        open(self.path("manifest/app.RVT.xml"), "w").write(
            '<Packages><Package name="A" installAs="x" path="x64/A/pkg.A.xml"/></Packages>')
        open(self.path("manifest/app.Other.xml"), "w").write('<Packages></Packages>')
        open(self.path("x64/A/pkg.A.xml"), "w").write('<Package><InstallFile type="MSI" file="x64/A/A.msi"/></Package>')
        self.assertEqual(run("odis", "list", self.d).stdout.split("\t")[0], "A")


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



class InstallerSource(Tmp):
    def setUp(self):
        super().setUp()
        self.inp = self.path("in"); self.dl = self.path("dl"); os.makedirs(self.inp); os.makedirs(self.dl)
        self.sums = self.path("CHECKSUMS.txt"); open(self.sums, "w").close()
        self.hashes = self.path("hashes.tsv"); self.src = self.path("source.json")

    def put(self, d, name, data=b"x"):
        p = os.path.join(d, name); os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f: f.write(data)
        return p

    def create_installer(self, d, year, base, updates=(), release="1", build="9"):
        """A fake Create Installer: a zip (7zz reads zips) with collection.xml and an update manifest."""
        p = os.path.join(d, f"Create_Installer_RVT_{year}_{release}_English_WIN64.exe")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("collection.xml", "<C><BrowserImageUrl>" + ";".join(
                f"https://dds.autodesk.com/x/{b}" for b in base) + "</BrowserImageUrl></C>")
            if updates:
                z.writestr("B/setup_ext.xml", '<E><Package sourceDir="U"/></E>')
                z.writestr("B/U/setup.xml", f"<S><BuildNumber>{build}</BuildNumber><Payload>" + "".join(
                    f'<File checkSum="{s}" sizePacked="{n}">https://dds.autodesk.com/u/{u}</File>' for u, n, s in updates)
                    + "</Payload></S>")
        return p

    def resolve(self, year="2025"):
        r = run("installer_source", "resolve", year, self.inp, self.dl, self.sums, self.src)
        return r, (json.load(open(self.src)) if os.path.exists(self.src) else None)

    def tool(self, *a):
        return run("installer_source", *a)

    def names(self, s, role):
        return [os.path.basename(f["path"]) for f in s["files"] if f["role"] == role]

    def extract(self, s):
        return [os.path.basename(f["path"]) for f in s["files"] if f.get("extract")]

    def test_create_installer_extracts_the_payload_not_the_downloader(self):
        self.create_installer(self.inp, "2025", ["RVT_2025_B_001_002.exe", "RVT_2025_B_002_002.7z"])
        r, s = self.resolve()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.extract(s), ["RVT_2025_B_002_002.7z"])

    def test_create_installer_picks_its_own_base_not_a_stale_set(self):
        self.create_installer(self.inp, "2025", ["RVT_2025_B_001_002.exe", "RVT_2025_B_002_002.7z"])
        self.put(self.inp, "RVT_2025_A_001_002.exe"); self.put(self.inp, "RVT_2025_A_002_002.7z")
        self.put(self.dl, "RVT_2025_B_001_002.exe"); self.put(self.dl, "RVT_2025_B_002_002.7z")
        r, s = self.resolve()
        self.assertEqual([f["path"] for f in s["files"] if f["role"] == "base"],
                         [os.path.join(self.dl, "RVT_2025_B_001_002.exe"), os.path.join(self.dl, "RVT_2025_B_002_002.7z")])
        self.assertIn("complete=1", r.stdout)

    def test_base_to_download_goes_to_downloads(self):
        self.create_installer(self.inp, "2025", ["RVT_2025_B_002_002.7z"])
        r, s = self.resolve()
        f = [f for f in s["files"] if f["role"] == "base"][0]
        self.assertEqual((f["path"], f["url"]), (os.path.join(self.dl, "RVT_2025_B_002_002.7z"), "https://dds.autodesk.com/x/RVT_2025_B_002_002.7z"))
        self.assertIn("complete=0", r.stdout)

    def test_several_create_installers_the_newest_build_wins(self):
        # sort -V puts 2024_3 after 2024_3_6; the update build decides
        new = self.create_installer(self.inp, "2024", ["RVT_2024_B.7z"], [("u36.exe", 1, "ab")], "3_6", "24.3.60.12")
        self.create_installer(self.inp, "2024", ["RVT_2024_A.7z"], [("u3.exe", 1, "cd")], "3", "24.3.0.30")
        r, s = self.resolve("2024")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([f["path"] for f in s["files"] if f["role"] == "create-installer"], [new])
        self.assertEqual(self.names(s, "base"), ["RVT_2024_B.7z"])
        self.assertIn("using Create_Installer_RVT_2024_3_6_English_WIN64.exe (build 24.3.60.12)", r.stderr)

    def test_an_unreadable_create_installer_next_to_a_good_one_is_skipped(self):
        good = self.create_installer(self.inp, "2024", ["RVT_2024_B.7z"], [("u.exe", 1, "ab")], "3", "24.3.0.30")
        self.put(self.inp, "Create_Installer_RVT_2024_9_English_WIN64.exe", b"junk")
        r, s = self.resolve("2024")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([f["path"] for f in s["files"] if f["role"] == "create-installer"], [good])

    def test_create_installer_without_a_base_list_is_an_error(self):
        self.create_installer(self.inp, "2025", [])
        r, _ = self.resolve()
        self.assertEqual(r.returncode, 1); self.assertIn("full installer", r.stderr)

    def test_parts_must_sit_together(self):
        self.put(self.inp, "Revit_2023_G1_Win_64bit_dlm_001_002.sfx.exe"); self.put(self.dl, "Revit_2023_G1_Win_64bit_dlm_002_002.sfx.exe")
        r, s = self.resolve("2023")
        self.assertEqual(s["kind"], "parts"); self.assertIn("complete=0", r.stdout)

    def test_a_complete_set_in_downloads_beats_an_incomplete_one_in_input(self):
        self.put(self.inp, "Revit_2023_A_dlm_001_002.sfx.exe")
        self.put(self.dl, "Revit_2023_B_dlm_001_002.sfx.exe"); self.put(self.dl, "Revit_2023_B_dlm_002_002.sfx.exe")
        r, s = self.resolve("2023")
        self.assertIn("complete=1", r.stdout); self.assertEqual(self.extract(s), ["Revit_2023_B_dlm_001_002.sfx.exe"])

    def test_archive_without_create_installer(self):
        self.put(self.inp, "RVT_2025_NA_win_db_001_002.exe", b"s"); self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"big" * 10)
        self.put(self.inp, "update/Revit_2025_10.exe"); self.put(self.inp, "update/Revit_2025_9.exe")
        r, s = self.resolve()
        self.assertEqual((s["kind"], self.extract(s)), ("archive", ["RVT_2025_NA_win_db_002_002.zip"]))
        self.assertEqual(self.names(s, "update"), ["Revit_2025_9.exe", "Revit_2025_10.exe"])   # as sort -V

    def test_a_downloader_without_its_payload(self):
        self.put(self.inp, "RVT_2025_NA_win_db_001_002.exe")
        r, s = self.resolve()
        self.assertEqual((s["kind"], s["problem"]), ("archive", "payload")); self.assertIn("complete=0", r.stdout)

    def test_finalize_gives_a_stable_source_id_and_lists_unknown_sums(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"payload")
        self.resolve(); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 0)
        s = json.load(open(self.src)); self.assertEqual(s["unknown"], ["RVT_2025_NA_win_db_002_002.zip"])
        self.resolve(); self.tool("finalize", self.src, self.hashes)
        self.assertEqual(json.load(open(self.src))["source_id"], s["source_id"]); self.assertIsNotNone(s["source_id"])

    def test_finalize_prints_checking_for_known_sums(self):
        p = self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"payload")
        open(self.sums, "w").write(hashlib.sha256(b"payload").hexdigest() + "  revit2025/RVT_2025_NA_win_db_002_002.zip  (x)\n")
        self.resolve(); r = self.tool("finalize", self.src, self.hashes)
        self.assertEqual(r.stdout, ">> checking RVT_2025_NA_win_db_002_002.zip\n")
        open(p, "wb").write(b"payloaX")
        self.resolve(); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 4)

    def test_update_conflict_and_equal_copies(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip")
        self.put(self.inp, "update/U.exe", b"one"); self.put(self.dl, "update/U.exe", b"one")
        self.resolve(); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 0)
        dot = self.path("dot.json"); shutil.copy(self.src, dot)
        self.resolve(); self.assertEqual(self.tool("compare", self.src, dot, self.hashes).stdout.strip(), "match")
        self.put(self.dl, "update/U.exe", b"two")
        self.resolve(); r = self.tool("finalize", self.src, self.hashes)
        self.assertEqual(r.returncode, 4); self.assertIn("U.exe", r.stderr)

    def test_two_copies_of_a_manifest_update(self):
        good = hashlib.sha256(b"u1").hexdigest()
        self.create_installer(self.inp, "2025", ["RVT_2025_B_002_002.7z"], [("U1.exe", 2, good)])
        self.put(self.dl, "RVT_2025_B_002_002.7z"); self.put(self.inp, "update/U1.exe", b"u1"); self.put(self.dl, "update/U1.exe", b"u1")
        self.resolve(); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 0)
        self.assertEqual(self.names(json.load(open(self.src)), "update"), ["U1.exe"])
        self.put(self.dl, "update/U1.exe", b"u2")
        self.resolve(); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 4)

    def test_compare_all_present(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"A")
        self.resolve(); self.tool("finalize", self.src, self.hashes)
        dot = self.path("dot.json"); shutil.copy(self.src, dot)
        self.assertEqual(self.tool("compare", self.src, dot, self.hashes).stdout.strip(), "match")
        self.put(self.inp, "update/U2.exe", b"new"); self.resolve()
        self.assertTrue(self.tool("compare", self.src, dot, self.hashes).stdout.startswith("mismatch"))

    def test_compare_create_installer_with_the_base_deleted(self):
        self.create_installer(self.inp, "2025", ["RVT_2025_B_002_002.7z"])
        self.put(self.dl, "RVT_2025_B_002_002.7z", b"base"); self.put(self.inp, "update/U1.exe", b"u1")
        self.resolve(); self.tool("finalize", self.src, self.hashes)
        dot = self.path("dot.json"); shutil.copy(self.src, dot)
        os.remove(os.path.join(self.dl, "RVT_2025_B_002_002.7z"))
        self.resolve(); self.assertEqual(self.tool("compare", self.src, dot, self.hashes).stdout.strip(), "match")
        self.put(self.inp, "update/U9.exe", b"added")          # the case of the last spec review
        self.resolve(); self.assertTrue(self.tool("compare", self.src, dot, self.hashes).stdout.startswith("mismatch"))
        os.remove(os.path.join(self.inp, "update", "U9.exe")); self.put(self.inp, "update/U1.exe", b"u!")   # same size
        self.resolve(); self.assertTrue(self.tool("compare", self.src, dot, self.hashes).stdout.startswith("mismatch"))
        os.remove(os.path.join(self.inp, "update", "U1.exe"))
        self.resolve(); self.assertTrue(self.tool("compare", self.src, dot, self.hashes).stdout.startswith("mismatch"))

    def test_only_updates_left(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"base"); self.put(self.inp, "update/U1.exe", b"u1")
        self.resolve(); self.tool("finalize", self.src, self.hashes)
        dot = self.path("dot.json"); shutil.copy(self.src, dot)
        os.remove(os.path.join(self.inp, "RVT_2025_NA_win_db_002_002.zip"))
        r, s = self.resolve(); self.assertEqual((r.returncode, s["kind"]), (0, "updates-only"))
        self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 0)
        self.assertIsNone(json.load(open(self.src))["source_id"])            # never a source for a fresh unpack
        self.resolve(); self.assertEqual(self.tool("compare", self.src, dot, self.hashes).stdout.strip(), "match")
        self.put(self.inp, "update/U2.exe", b"u2"); self.resolve()
        self.assertTrue(self.tool("compare", self.src, dot, self.hashes).stdout.startswith("mismatch"))
        self.put(self.dl, "update/U2.exe", b"other"); self.resolve()
        self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 4)
        os.remove(os.path.join(self.dl, "update", "U2.exe"))
        r, _ = self.resolve(); self.assertIn("complete=0", r.stdout)                      # never a complete installer
        self.assertFalse(json.loads(self.tool("detect", self.inp).stdout)["complete"])

    def test_downloader_left_with_updates(self):
        self.put(self.inp, "RVT_2025_NA_win_db_001_002.exe"); self.put(self.inp, "update/U1.exe", b"u1")
        r, s = self.resolve()
        self.assertEqual((s["kind"], s["problem"], self.names(s, "update")), ("updates-only", "payload", ["U1.exe"]))
        self.assertIn("complete=0", r.stdout)

    def test_known_sum_of_a_local_update_is_checked(self):
        self.put(self.inp, "RVT_2024_NA_win_db_002_002.zip"); self.put(self.inp, "update/Revit_2024_3_6.exe", b"broken")
        open(self.sums, "w").write("0" * 64 + "  revit2024/update/Revit_2024_3_6.exe  (x)\n")
        self.resolve("2024"); self.assertEqual(self.tool("finalize", self.src, self.hashes).returncode, 4)

    def test_compare_without_any_source(self):
        self.resolve()
        dot = self.path("dot.json"); json.dump({"kind": "archive", "files": [], "source_id": "x", "manifest_id": None}, open(dot, "w"))
        self.assertEqual(self.tool("compare", self.src, dot, self.hashes).stdout.strip(), "nosource")

    def test_compare_refuses_an_unreadable_dot_source(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip"); self.resolve()
        bad = self.path("bad.json"); open(bad, "w").write("{")
        self.assertEqual(self.tool("compare", self.src, bad, self.hashes).returncode, 1)

    def test_hash_cache_sees_a_same_size_change_in_the_same_second(self):
        p = self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"AAAA"); self.resolve(); self.tool("finalize", self.src, self.hashes)
        a = json.load(open(self.src))["source_id"]; st = os.stat(p)
        open(p, "wb").write(b"BBBB"); os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
        self.resolve(); self.tool("finalize", self.src, self.hashes)
        self.assertNotEqual(json.load(open(self.src))["source_id"], a)

    def test_two_writers_of_the_hash_cache(self):
        self.put(self.inp, "RVT_2025_NA_win_db_002_002.zip", b"x" * 100000); self.resolve()
        a = self.path("a.json"); b = self.path("b.json"); shutil.copy(self.src, a); shutil.copy(self.src, b)
        for _ in range(10):
            ps = [subprocess.Popen([sys.executable, "-I", os.path.join(TOOLS, "installer_source.py"), "finalize", x, self.hashes],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) for x in (a, b)]
            self.assertEqual([q.wait() for q in ps], [0, 0])

    def test_detect(self):
        self.put(self.inp, "Revit_2020_G1_Win_64bit_r3_dlm_002_003.sfx.exe"); self.put(self.inp, "Revit_2020_G1_Win_64bit_r3_dlm_003_003.sfx.exe")
        d = json.loads(self.tool("detect", self.inp).stdout)
        self.assertEqual((d["year"], d["kind"], d["complete"]), ("2020", "parts", False))
        self.assertEqual(d["missing"], ["Revit_2020_G1_Win_64bit_r3_dlm_001_003.sfx.exe"])   # a missing first part too

    def test_detect_create_installer_alone_is_downloadable_not_complete(self):
        self.create_installer(self.inp, "2026", ["RVT_2026_B_002_002.7z"])
        d = json.loads(self.tool("detect", self.inp).stdout)
        self.assertEqual((d["year"], d["kind"], d["complete"], d["downloadable"]), ("2026", "create-installer", False, True))

LOCK = """version = 1
[[package]]
name = "root"
version = "0.1.0"
source = { virtual = "." }
dependencies = [
    { name = "httpx" },
    { name = "mcp", extra = ["cli"] },
]
[package.optional-dependencies]
test = [{ name = "pytest" }]

[[package]]
name = "httpx"
version = "0.28.1"
source = { registry = "https://pypi.org/simple" }
dependencies = [{ name = "anyio" }, { name = "winonly", marker = "sys_platform == 'win32'" }]
sdist = { url = "https://x/httpx.tar.gz", hash = "sha256:aa" }
wheels = [{ url = "https://x/httpx.whl", hash = "sha256:bb" }]

[[package]]
name = "mcp"
version = "1.30.0"
source = { registry = "https://pypi.org/simple" }
dependencies = [{ name = "anyio" }, { name = "old", marker = "python_full_version < '3.13'" }]
wheels = [{ url = "https://x/mcp.whl", hash = "sha256:cc" }]
[package.optional-dependencies]
cli = [{ name = "typer" }, { name = "newer", marker = "python_full_version < '3.15' and platform_python_implementation != 'PyPy'" }]

[[package]]
name = "anyio"
version = "4.15.1"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/anyio.whl", hash = "sha256:dd" }]

[[package]]
name = "typer"
version = "1.0"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/typer-mac.whl", hash = "sha256:ee" }, { url = "https://x/typer-win.whl", hash = "sha256:ff" }]

[[package]]
name = "newer"
version = "2.0"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/newer.whl", hash = "sha256:11" }]

[[package]]
name = "old"
version = "1.0"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/old.whl", hash = "sha256:22" }]

[[package]]
name = "winonly"
version = "1.0"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/win.whl", hash = "sha256:33" }]

[[package]]
name = "pytest"
version = "9.0.3"
source = { registry = "https://pypi.org/simple" }
wheels = [{ url = "https://x/pytest.whl", hash = "sha256:44" }]
"""


class PythonMcpRequirements(Tmp):
    """tools/gen_python_mcp_requirements.py: the pinned packages for python-build-standalone 3.14 on macOS arm64. A
    maintainer's tool for a new pin, run with Python 3.11 or newer (tomllib): skipped under the system 3.9."""
    def gen(self):
        if sys.version_info < (3, 11):
            self.skipTest("tomllib needs Python 3.11")
        open(self.path("uv.lock"), "w").write(LOCK)
        return run("gen_python_mcp_requirements", self.path("uv.lock"))

    def test_follows_the_root_with_the_cli_extra_and_markers(self):
        r = self.gen()
        self.assertEqual(r.returncode, 0, r.stderr)
        names = [l.split("==")[0] for l in r.stdout.splitlines() if l and not l.startswith("#")]
        self.assertEqual(names, ["anyio", "httpx", "mcp", "newer", "typer"])   # sorted; no old, winonly, pytest

    def test_every_file_hash_of_a_package(self):
        lines = self.gen().stdout.splitlines()
        self.assertIn("httpx==0.28.1 --hash=sha256:aa --hash=sha256:bb", lines)
        self.assertIn("typer==1.0 --hash=sha256:ee --hash=sha256:ff", lines)

    def test_deterministic(self):
        self.assertEqual(self.gen().stdout, self.gen().stdout)

    def test_the_committed_file(self):
        txt = open(os.path.join(TOOLS, "python-mcp-requirements.txt")).read()
        self.assertIn("6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d", txt.splitlines()[0])
        pins = [l for l in txt.splitlines() if l and not l.startswith("#")]
        self.assertTrue(any(l.startswith("mcp==1.30.0 ") for l in pins))
        self.assertTrue(any(l.startswith("httpx==0.28.1 ") for l in pins))
        self.assertTrue(all("--hash=sha256:" in l for l in pins))


class PyrevitIni(Tmp):
    """tools/pyrevit_ini.py: one key of pyRevit's pyRevit_config.ini, everything else byte for byte."""
    INI = "[core]\nbincache = true\n\n[routes]\nEnabled = True\ncore_api = false\n\n[telemetry]\nactive = false\n"

    def ini(self, text=None, crlf=False):
        t = self.INI if text is None else text
        with open(self.path("c.ini"), "wb") as f:
            f.write((t.replace("\n", "\r\n") if crlf else t).encode())
        return self.path("c.ini")

    def text(self):
        with open(self.path("c.ini"), "rb") as f:
            return f.read().decode()

    def test_replaces_a_key_in_any_case(self):
        p = self.ini()
        self.assertEqual(run("pyrevit_ini", "set", p, "routes", "enabled", "true").returncode, 0)
        self.assertEqual(self.text(), self.INI.replace("Enabled = True", "enabled = true"))

    def test_adds_a_key_at_the_end_of_its_section(self):
        p = self.ini()
        run("pyrevit_ini", "set", p, "routes", "host", '"127.0.0.1"')
        self.assertEqual(self.text(), self.INI.replace("core_api = false\n", 'core_api = false\nhost = "127.0.0.1"\n'))

    def test_adds_a_section(self):
        p = self.ini()
        run("pyrevit_ini", "set", p, "revit-mcp-python.extension", "disabled", "false")
        self.assertEqual(self.text(), self.INI + "\n[revit-mcp-python.extension]\ndisabled = false\n")

    def test_crlf_stays_crlf(self):
        p = self.ini(crlf=True)
        run("pyrevit_ini", "set", p, "routes", "port", "48884")
        self.assertNotIn("\n", self.text().replace("\r\n", ""))
        self.assertIn("port = 48884\r\n", self.text())

    def test_get(self):
        p = self.ini()
        r = run("pyrevit_ini", "get", p, "ROUTES", "enabled")
        self.assertEqual((r.returncode, r.stdout), (0, "True\n"))
        self.assertEqual(run("pyrevit_ini", "get", p, "routes", "host").returncode, 1)

    def test_missing_file(self):
        self.assertEqual(run("pyrevit_ini", "set", self.path("none.ini"), "routes", "port", "1").returncode, 1)

    def test_duplicates_become_one_line(self):
        p = self.ini("[routes]\nhost = \"127.0.0.1\"\nenabled = true\nHost = \"0.0.0.0\"\n")
        run("pyrevit_ini", "set", p, "routes", "host", '"127.0.0.1"')
        self.assertEqual(self.text(), '[routes]\nhost = "127.0.0.1"\nenabled = true\n')

    def test_get_takes_the_last_like_pyrevit(self):
        p = self.ini("[routes]\nhost = \"127.0.0.1\"\nhost = \"0.0.0.0\"\n")
        self.assertEqual(run("pyrevit_ini", "get", p, "routes", "host").stdout, '"0.0.0.0"\n')


class PythonMcpRun(Tmp):
    """tools/python_mcp_run.py: runs upstream main.py with a fixed endpoint and the pairing token from a pipe."""
    TOKEN = "0123456789abcdef" * 4
    MAIN = (
        "import os, sys, json\n"
        "import revit_mcp.pairing as p\n"
        "lock = int(os.environ.get('TEST_LOCK_FD', '-1'))\n"
        "try:\n    os.fstat(lock); closed = False\nexcept OSError:\n    closed = True\n"
        "sys.stderr.write(json.dumps({'host': os.environ.get('REVIT_HOST'), 'port': os.environ.get('REVIT_PORT'),\n"
        "    'token': p.get_token(), 'argv': sys.argv, 'environ': dict(os.environ), 'lock_closed': closed}) + '\\n')\n"
        "print(json.dumps({'jsonrpc': '2.0'}))\n")

    def setUp(self):
        super().setUp()
        os.makedirs(self.path("src/revit_mcp"))
        open(self.path("src/revit_mcp/__init__.py"), "w").close()
        with open(self.path("src/revit_mcp/pairing.py"), "w") as f:
            f.write("def get_token():\n    raise RuntimeError('DPAPI')\n")
        with open(self.path("src/main.py"), "w") as f:
            f.write(self.MAIN)

    def wrap(self, token=None, env=None):
        r, w = os.pipe()
        os.write(w, ((self.TOKEN if token is None else token) + "\n").encode())
        os.close(w)
        lock = os.open(self.path("lock"), os.O_CREAT | os.O_RDWR)
        e = dict(os.environ, HOME=self.path("home"), TEST_LOCK_FD=str(lock), **(env or {}))
        try:
            p = subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "python_mcp_run.py"), "revit-macos-python-mcp",
                                "/x/rvt2020-a", self.path("src"), "--token-fd", str(r), "--lock-fd", str(lock)],
                               capture_output=True, text=True, pass_fds=(r, lock), env=e, timeout=30)
        finally:
            os.close(r)
            os.close(lock)
        info = None
        for line in p.stderr.splitlines():
            if line.startswith("{"):
                info = json.loads(line)
        return p, info

    def test_endpoint_fixed_despite_env(self):
        p, info = self.wrap(env={"REVIT_HOST": "localhost", "REVIT_PORT": "1"})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((info["host"], info["port"]), ("127.0.0.1", "48884"))

    def test_token_not_in_argv_or_environ(self):
        p, info = self.wrap()
        self.assertEqual(info["token"], self.TOKEN)
        self.assertNotIn(self.TOKEN, json.dumps(info["argv"]) + json.dumps(info["environ"]))

    def test_bad_token_exit_2_stdout_empty(self):
        for bad in ("", "xyz", self.TOKEN.upper()):
            p, info = self.wrap(token=bad)
            self.assertEqual((p.returncode, p.stdout, info), (2, "", None), bad)

    def test_lock_fd_closed_before_main(self):
        p, info = self.wrap()
        self.assertTrue(info["lock_closed"])

    def test_stdout_only_from_main(self):
        p, info = self.wrap()
        self.assertEqual(p.stdout, '{"jsonrpc": "2.0"}\n')


class LeftoversTest(Tmp):
    """tools/leftovers.py: what is left over, from canned ps and lsof answers; the signals only reach a sleep of its own."""
    def setUp(self):
        super().setUp()
        self.L = load("leftovers")
        self.b = self.path("Bottles")
        os.makedirs(os.path.join(self.b, "live", "revit-macos"))
        os.environ.pop("REVIT_CLEANUP_ONLY", None)
        os.environ["REVIT_CLEANUP_AGE"] = "60"; os.environ["REVIT_GDRIVE_STUCK_AGE"] = "1800"

    def tearDown(self):
        for k in ("REVIT_CLEANUP_AGE", "REVIT_GDRIVE_STUCK_AGE"):
            os.environ.pop(k, None)
        super().tearDown()

    def proc(self, command, age=3600, comm="", ppid=1, cpu=0.0):
        return {"ppid": ppid, "age": age, "cpu": cpu, "command": command, "comm": comm or command.split(" ")[0]}

    def at(self, bottle):
        return [("DIR", f"{self.b}/{bottle}/drive_c/windows", "cwd")]

    SERVER = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver"
    DEVICE = "C:\\windows\\system32\\winedevice.exe"

    def classify(self, procs, files, **kw):
        items, skipped = self.L.classify(procs, files, self.b, now_pid=1, **kw)
        return {i["pid"]: i["reason"] for i in items}, skipped

    def test_secs(self):
        self.assertEqual(self.L.secs("05"), 5)
        self.assertEqual(self.L.secs("08:37:59"), 31079)
        self.assertEqual(self.L.secs("01-17:47:38"), 150458)

    def test_no_wineserver_gone_bottle_and_idle(self):
        procs = {10: self.proc(self.DEVICE), 11: self.proc("C:\\windows\\system32\\services.exe"),
                 12: self.proc(self.SERVER + " -p0"), 13: self.proc("C:\\windows\\system32\\rpcss.exe")}
        files = {10: self.at("probe-drag"), 11: self.at("live"), 12: [("DIR", f"{self.b}/live", "3")], 13: self.at("live")}
        self.assertEqual(self.classify(procs, files), ({10: "bottle_gone"}, []))
        self.assertEqual(self.classify(procs, files, everything=True)[0], {10: "bottle_gone", 11: "idle", 12: "idle", 13: "idle"})
        del procs[12]
        self.assertEqual(self.classify(procs, files)[0], {10: "bottle_gone", 11: "no_wineserver", 13: "no_wineserver"})
        self.assertEqual(self.classify(procs, files, bottle="probe-drag")[0], {10: "bottle_gone"})

    def test_a_native_program_with_a_bottle_file_open_is_not_wine(self):
        procs = {20: self.proc(f"/usr/bin/less {self.b}/live/revit-macos/wineserver.log"),
                 21: self.proc(f"/usr/bin/tail -f {self.b}/live/drive_c/x.exe.log"), 22: self.proc("/bin/zsh -c wine-thing")}
        files = {20: [("REG", f"{self.b}/live/revit-macos/wineserver.log", "3")], 21: self.at("live"), 22: self.at("live")}
        self.assertEqual(self.classify(procs, files, everything=True), ({}, []))

    def test_a_wineserver_found_by_its_server_folder(self):
        st = os.stat(os.path.join(self.b, "live"))
        procs = {11: self.proc("C:\\windows\\system32\\services.exe"), 12: self.proc(self.SERVER)}
        files = {11: self.at("live"), 12: [("DIR", "/private/tmp/.wine-501/server-%x-%x" % (st.st_dev, st.st_ino), "cwd")]}
        self.assertEqual(self.classify(procs, files)[0], {})
        self.assertEqual(self.classify(procs, files, everything=True)[0], {11: "idle", 12: "idle"})

    def test_a_wineserver_of_no_known_bottle_makes_no_wineserver_unknown(self):
        procs = {10: self.proc(self.DEVICE), 11: self.proc("C:\\windows\\system32\\services.exe"), 12: self.proc(self.SERVER),
                 30: self.proc("C:\\windows\\system32\\conhost.exe --server 0x3c")}
        files = {10: self.at("probe-drag"), 11: self.at("live"), 12: [("DIR", "/private/tmp/.wine-501/server-1-2", "cwd")]}
        got, skipped = self.classify(procs, files)
        self.assertEqual(got, {10: "bottle_gone"})   # a deleted bottle is still a fact; 11 and 30 may have a server
        self.assertEqual(skipped, [{"bottle": "live", "why": "wineserver_unknown"}])

    def test_young_programs_and_revit_bottles_are_left_alone(self):
        procs = {10: self.proc(self.DEVICE, age=5),
                 20: self.proc("C:\\Program Files\\Autodesk\\Revit 2027\\Revit.exe"), 21: self.proc("C:\\windows\\system32\\services.exe")}
        files = {10: self.at("live"), 20: self.at("probe-drag"), 21: self.at("probe-drag")}
        self.assertEqual(self.classify(procs, files), ({}, [{"bottle": "probe-drag", "why": "revit_running"}]))

    def test_programs_in_no_bottle_only_without_any_wineserver(self):
        procs = {30: self.proc("C:\\windows\\system32\\conhost.exe --server 0x3c --headless"),
                 31: self.proc("/cx/lib/wine/x86_64-windows/winewrapper.exe --run -- notepad"),
                 32: self.proc("/usr/bin/vim notes-about-wine.exe")}
        self.assertEqual(self.classify(procs, {})[0], {30: "no_wineserver", 31: "no_wineserver"})
        procs[12] = self.proc(self.SERVER)
        self.assertEqual(self.classify(procs, {12: [("DIR", f"{self.b}/live", "3")]})[0], {})

    def test_helpers(self):
        tp = "/A/T.app/Contents/Helpers/T Trackpad.app/Contents/MacOS/T Trackpad --session S --parent 38111:Wed Oct 28 10:45:29 2026 --engine /e --data /d"
        procs = {40: self.proc(tp), 41: self.proc("python3 /r/tools/python_mcp_run.py revit-macos-python-mcp /b x"),
                 42: self.proc("python3 /r/tools/python_mcp_run.py revit-macos-python-mcp /b x", ppid=500)}
        self.assertEqual(self.classify(procs, {}, started={38111: "Wed Oct 28 10:45:29 2026"}.get)[0], {41: "parent_gone"})
        got = self.classify(procs, {}, started=lambda p: "Thu Oct 29 09:00:00 2026")[0]
        self.assertEqual(got, {40: "parent_gone", 41: "parent_gone"})   # pid 38111 was reused by another process
        self.assertEqual(self.L.short(tp), "T Trackpad")

    def beat(self, pid, started, progress):
        with open(os.path.join(self.b, "live", "revit-macos", "gdrive-warm-%d" % pid), "w") as f:
            json.dump({"pid": pid, "started": started, "progress": progress}, f)

    def test_a_warm_is_stuck_by_its_heartbeat(self):
        now = 1_800_000_000
        warm = f"/usr/bin/python3 -I /r/tools/gdrive.py warm {self.b}/live G:\\Shared 2027"
        procs = {43: self.proc(warm, age=7200), 44: self.proc(warm, age=7200), 45: self.proc(warm, age=7200),
                 46: self.proc(warm, age=600)}
        self.beat(43, now - 7200, now - 60)      # slow, but it moved a minute ago
        self.beat(44, now - 7200, now - 1900)    # nothing for 31 minutes
        self.beat(45, now - 90000, now - 60)     # a file an earlier process of that PID left: not its own
        self.assertEqual(self.classify(procs, {}, now=now)[0], {44: "stuck", 45: "stuck"})   # 45, 46: by their age
        self.assertEqual(self.classify(procs, {}, bottle="other", now=now)[0], {})

    def test_signals_only_reach_the_same_process(self):
        p = subprocess.Popen(["sleep", "30"])
        try:
            st = self.L.starts([p.pid])[p.pid]
            old = {"pid": p.pid, "start": st - 5, "reason": "no_wineserver", "bottle": "x"}   # the PID was reused
            self.assertEqual(self.L.still([old]), [])
            self.L.signal_all([old], 9)
            time.sleep(0.2)
            self.assertIsNone(p.poll())
            same = dict(old, start=st)
            self.assertEqual(self.L.still([same]), [same])
            self.assertEqual(self.L.close(self.b, "/nonexistent", [same]), ([], []))   # no wineserver -k: by PID only
            self.assertIsNotNone(p.poll())
        finally:
            p.kill(); p.wait()


if __name__ == "__main__":
    unittest.main()
