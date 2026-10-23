# SPDX-License-Identifier: MIT
"""Unit tests for the Python helpers in tools/. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; nothing from Autodesk or Microsoft is needed."""
import hashlib, importlib.util, io, json, os, shutil, struct, subprocess, sys, tempfile, unittest, zipfile

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

if __name__ == "__main__":
    unittest.main()
