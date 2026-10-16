# SPDX-License-Identifier: MIT
"""Unit tests for tools/bottleread.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every input is generated here; nothing from Autodesk, Microsoft or a real bottle is needed."""
import importlib.util, os, struct, subprocess, sys, tempfile, time, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


br = load("bottleread")


def pe_with_version(ms_hi, ms_lo, ls_hi, ls_lo, pad=5000):
    """A minimal file that starts like a PE and holds a VS_FIXEDFILEINFO somewhere after some padding."""
    fixed = b"\xbd\x04\xef\xfe" + struct.pack("<IIII", 0x00010000, (ms_hi << 16) | ms_lo, (ls_hi << 16) | ls_lo, 0)
    decoy = b"\xbd\x04\xef\xfe" + struct.pack("<I", 0x12345678)   # the signature bytes, but not a real struct
    return b"MZ" + bytes(62) + b"Wine builtin DLL" + bytes(pad) + decoy + bytes(7) + fixed + bytes(100)


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
        with open(p, "wb" if isinstance(data, bytes) else "w", **({} if isinstance(data, bytes) else {"encoding": "utf-8"})) as f:
            f.write(data)
        return p

    def snapshot(self):
        out = {}
        for root, dirs, files in os.walk(self.d):
            for n in dirs + files:
                p = os.path.join(root, n)
                st = os.lstat(p)
                out[p] = (st.st_ino, st.st_mtime_ns, st.st_size, st.st_mode)
        return out


class Conf(Tmp):
    def test_sections_and_escapes(self):
        p = self.write("cxbottle.conf", '[Bottle]\n"Description" = "Revit 2027"\n"Template" = "win10_64"\n'
                       '[EnvironmentVariables]\n"A" = "x \\"q\\" y"\n"B\\\\C" = ""\nnot a line\n')
        c = br.read_conf(p)
        self.assertEqual(c["Bottle"]["Description"], "Revit 2027")
        self.assertEqual(c["EnvironmentVariables"]["A"], 'x "q" y')
        self.assertEqual(c["EnvironmentVariables"]["B\\C"], "")

    def test_missing_file_and_no_env_section_changes_nothing(self):
        self.assertEqual(br.read_conf(self.path("none.conf")), {})
        p = self.write("cxbottle.conf", '[Bottle]\n"Description" = "Revit 2025"\n')
        before = self.snapshot()
        br.read_conf(p)
        self.assertEqual(before, self.snapshot())


class Ini(Tmp):
    TEXT = "[Directories" + "ENU]\r\nDefaultTemplate=Metric=C:\\T\\a b.rte\r\n; c\r\n[Graphics]\r\nAntialiasing=0\r\n"

    def test_utf16_with_and_without_bom(self):
        for name, raw in (("bom.ini", b"\xff\xfe" + self.TEXT.encode("utf-16-le")),
                          ("nobom.ini", self.TEXT.encode("utf-16-le")),
                          ("utf8.ini", self.TEXT.encode("utf-8"))):
            ini = br.read_ini(self.write(name, raw))
            self.assertEqual(br.ini_get(ini, "directoriesenu", "defaulttemplate"), "Metric=C:\\T\\a b.rte", name)
            self.assertEqual(br.ini_get(ini, "Graphics", "Antialiasing"), "0", name)

    def test_read_leaves_file_and_folder_alone(self):
        p = self.write("Revit.ini", b"\xff\xfe" + self.TEXT.encode("utf-16-le"))
        before = self.snapshot()
        br.read_ini(p)
        self.assertEqual(before, self.snapshot())
        self.assertFalse(os.path.exists(p + ".orig"))


class Reg(Tmp):
    def reg(self):
        text = "\n".join([
            "WINE REGISTRY Version 2", ";; All keys relative to \\\\Machine", "", "#arch=win64", "",
            "[Software\\\\Wine\\\\DllOverrides] 1697000000", "#time=1d9a2b3c4d5e6f7",
            '"mscoree"="native"', '"*D3D9"="native,builtin"', "",
            "[System\\\\CurrentControlSet\\\\Services\\\\AdskLicensingService] 1697000001",
            '"ImagePath"=str(2):"\\"C:\\\\Program Files\\\\x\\\\svcshim.exe\\" 16.1"',
            '"Start"=dword:00000002', '"Blob"=hex:01,02,\\', "  03,ff",
            '"Exp"=hex(2):25,00,41,00,25,00,00,00', '"Multi"=str(7):"a\\0b\\0"', '@="dflt"',
            '"Tab\\tName"="\\x00e9t\\303"', "",
            "[Software\\\\Classes\\\\CLSID\\\\{4590F811-1D3A-11D0-891F-00AA004B2E24}\\\\InprocServer32] 1",
            '@="C:\\\\windows\\\\system32\\\\wbemshim.dll"', ""])
        return self.write("system.reg", text)

    def test_values_and_types(self):
        r = br.read_reg(self.reg())
        self.assertEqual(br.reg_get(r, "Software\\Wine\\DllOverrides", "mscoree"), ("sz", "native"))
        self.assertEqual(br.reg_get(r, "software\\wine\\dlloverrides", "*d3d9"), ("sz", "native,builtin"))
        svc = "System\\CurrentControlSet\\Services\\AdskLicensingService"
        self.assertEqual(br.reg_get(r, svc, "ImagePath"), ("expand_sz", '"C:\\Program Files\\x\\svcshim.exe" 16.1'))
        self.assertEqual(br.reg_get(r, svc, "Start"), ("dword", 2))
        self.assertEqual(br.reg_get(r, svc, "Blob"), ("hex", b"\x01\x02\x03\xff"))
        self.assertEqual(br.reg_get(r, svc, "Exp"), ("expand_sz", "%A%"))
        self.assertEqual(br.reg_get(r, svc, "Multi"), ("multi_sz", ["a", "b"]))
        self.assertEqual(br.reg_get(r, svc), ("sz", "dflt"))
        self.assertEqual(br.reg_get(r, svc, "Tab\tName"), ("sz", "\u00e9t\u00c3"))
        clsid = "Software\\Classes\\CLSID\\{4590F811-1D3A-11D0-891F-00AA004B2E24}\\InprocServer32"
        self.assertEqual(br.reg_get(r, clsid), ("sz", "C:\\windows\\system32\\wbemshim.dll"))
        self.assertIsNone(br.reg_get(r, "Software\\Nope"))

    def test_cli_reads_one_key(self):
        p = self.reg()
        out = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "bottleread.py"), "reg", p,
                              "software\\wine\\dlloverrides"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn('"mscoree"', out.stdout)


class Pe(Tmp):
    def test_file_version_skips_decoys(self):
        p = self.write("Revit.exe", pe_with_version(27, 3, 0, 28))
        self.assertEqual(br.pe_file_version(p), "27.3.0.28")

    def test_version_across_chunk_boundary(self):
        p = self.write("big.exe", pe_with_version(26, 5, 0, 55, pad=(1 << 20) - 70))
        self.assertEqual(br.pe_file_version(p), "26.5.0.55")

    def test_not_a_pe(self):
        self.assertIsNone(br.pe_file_version(self.write("x.exe", b"ELF" + bytes(100))))
        self.assertIsNone(br.pe_file_version(self.path("missing.exe")))

    def test_markers(self):
        self.assertEqual(br.pe_marker(self.write("a.dll", b"MZ" + bytes(62) + b"DXVK native  DLL")), b"DXVK native  DLL")
        self.assertEqual(br.pe_marker(self.write("b.dll", b"MZ" + bytes(62) + b"Wine orig    DLL")), b"Wine orig    DLL")
        self.assertIsNone(br.pe_marker(self.write("c.dll", b"MZ" + bytes(300) + b"Wine builtin DLL")))


class Journals(Tmp):
    def test_newest_by_time(self):
        d = br.journals_dir(self.d, 2027)
        os.makedirs(d)
        for i, n in enumerate(["journal.0001.txt", "journal.0003.txt", "journal.0002.txt", "notes.txt"]):
            p = os.path.join(d, n)
            with open(p, "w") as f:
                f.write(n)
            os.utime(p, (time.time() - 100 + i * 10,) * 2)
        self.assertEqual(os.path.basename(br.newest_journal(self.d, 2027)), "journal.0002.txt")
        self.assertIsNone(br.newest_journal(self.d, 2020))

    def test_read_lines_binary_long_and_capped(self):
        data = b"one\r\n" + b"\xff\xfe bad \x00 bytes\n" + b"x" * 200000 + b"\nlast\n" + b"after the cap\n"
        p = self.write("j.txt", data)
        lines = list(br.read_lines(p, max_bytes=len(data) - len(b"after the cap\n"), max_line=100))
        self.assertEqual(lines[0], "one")
        self.assertIn("bad", lines[1])
        self.assertEqual(lines[2], "x" * 100)
        self.assertEqual(lines[3], "last")
        self.assertEqual(len(lines), 4)

    def test_read_lines_from_an_offset(self):
        data = b"first\nsecond line\nthird\n"
        p = self.write("o.txt", data)
        self.assertEqual(list(br.read_lines(p, start=3)), ["second line", "third"])   # inside a line: the next one
        self.assertEqual(list(br.read_lines(p, start=6)), ["second line", "third"])   # at a line's start: that one
        self.assertEqual(list(br.read_lines(p, start=7)), ["third"])
        self.assertEqual(list(br.read_lines(p, start=len(data))), [])
        self.assertEqual(list(br.read_lines(p, start=len(data) + 10)), [])
        self.assertEqual(list(br.read_lines(p, start=6, max_bytes=12)), ["second"])


if __name__ == "__main__":
    unittest.main()
