# SPDX-License-Identifier: MIT
"""Unit tests for tools/rvtfile.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every file is generated here: compound files with the three kinds of BasicFileInfo that Revit wrote from 2008 to 2027."""
import importlib.util, json, os, struct, subprocess, sys, tempfile, threading, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
spec = importlib.util.spec_from_file_location("rvtfile", os.path.join(TOOLS, "rvtfile.py"))
rf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rf)

FREE, EOC, FATSEC = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD


def text(lines, odd=True):
    """A stream as Revit writes it: a binary part, then lines of UTF-16LE, on an odd byte when odd."""
    return b"\x0e" + b"\0" * (12 if odd else 13) + "\r\n".join(lines + [""]).encode("utf-16-le")


MODERN = ["Worksharing: Not enabled", "Username: ", "Central Model Path: ", "Format: 2021", "Build: 20200220_1100(x64)",
          "Last Save Path: Z:\\Format: 2019\\a.rvt"]
SHARED = ["Worksharing: Central", "Format: 2025", "Build: 20240516_1515(x64)"]
OLD = ["Worksharing: Not enabled", "Revit Build: Autodesk Revit 2017 (Build: 20160225_1515(x64))"]
LT = ["Worksharing: Not enabled", "Revit Build: Autodesk Revit LT 2018 (Build: 20170223_1515(x64))"]
ANCIENT = ["Worksharing: Not enabled", "Revit Build: 20080126_1900"]


def direntry(name, kind, start, size, child=FREE):
    n = name.encode("utf-16-le") + b"\0\0"
    e = n.ljust(64, b"\0") + struct.pack("<HBB", len(n), kind, 1)
    e += struct.pack("<III", FREE, FREE, child) + b"\0" * 36
    return e + struct.pack("<IQ", start, size)


def compound(stream, name="BasicFileInfo", shift=12, loop=False, cut=None):
    """A compound file with one stream: in the mini stream when small, in the sectors of the file otherwise."""
    ss, ms, cutoff = 1 << shift, 64, 4096
    secs = {}                     # sector number → bytes
    fat = {}

    def put(n, data, nxt):
        secs[n] = data.ljust(ss, b"\0")
        fat[n] = nxt

    def run(first, data):
        count = max(1, (len(data) + ss - 1) // ss)
        for i in range(count):
            put(first + i, data[i * ss:(i + 1) * ss], first + i + 1 if i + 1 < count else EOC)
        return first + count

    fat[0] = FATSEC
    d0 = 1
    if len(stream) < cutoff:
        nxt = d0 + 1
        minifat = [(i + 1 if (i + 1) * ms < len(stream) else EOC) for i in range(max(1, (len(stream) + ms - 1) // ms))]
        if loop:
            minifat[-1] = 0
        mf0 = nxt
        nxt = run(nxt, struct.pack("<%dI" % len(minifat), *minifat).ljust(ss, b"\xff"))
        root0 = nxt
        nxt = run(nxt, stream)
        ents = direntry("Root Entry", 5, root0, len(stream), 1) + direntry(name, 2, 0, len(stream))
    else:
        mf0 = EOC
        s0 = d0 + 1
        nxt = run(s0, stream)
        if loop:
            fat[s0] = s0
        ents = direntry("Root Entry", 5, EOC, 0, 1) + direntry(name, 2, s0, len(stream))
    put(d0, ents, EOC)
    words = [fat.get(i, FREE) for i in range(ss // 4)]
    secs[0] = struct.pack("<%dI" % len(words), *words)
    h = rf.MAGIC + b"\0" * 16 + struct.pack("<HHHHH", 62, 4 if shift == 12 else 3, 0xFFFE, shift, 6) + b"\0" * 6
    h += struct.pack("<IIII", 0, 1, d0, 0) + struct.pack("<IIIII", cutoff, mf0, 1, EOC, 0)
    h += struct.pack("<I", 0) + b"\xff" * (108 * 4)
    assert len(h) == 512
    out = h.ljust(ss, b"\0") + b"".join(secs[i] for i in sorted(secs))
    return out[:cut] if cut else out


class Tmp(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self._d.name)
        self.addCleanup(self._d.cleanup)

    def file(self, name, data):
        p = os.path.join(self.d, name)
        with open(p, "wb") as f:
            f.write(data)
        return p


class Info(Tmp):
    def fmt(self, lines, **k):
        return rf.info(self.file("a.rvt", compound(text(lines), **k)))

    def test_since_2019_format_line_wins_over_a_path_that_looks_like_it(self):
        r = self.fmt(MODERN)
        self.assertEqual((r["format"], r["build"], r["worksharing"], r["error"]), (2021, "20200220_1100", "Not enabled", ""))

    def test_2016_to_2018_year_from_the_build_line(self):
        self.assertEqual(self.fmt(OLD)["format"], 2017)
        self.assertEqual(self.fmt(LT)["format"], 2018)

    def test_older_files_name_no_year(self):
        r = self.fmt(ANCIENT)
        self.assertIsNone(r["format"])
        self.assertEqual(r["error"], "")

    def test_text_on_an_even_byte(self):
        p = self.file("a.rvt", compound(text(MODERN, odd=False)))
        self.assertEqual(rf.info(p)["format"], 2021)

    def test_worksharing_is_reported(self):
        self.assertEqual(self.fmt(SHARED)["worksharing"], "Central")

    def test_512_byte_sectors(self):
        self.assertEqual(self.fmt(MODERN, shift=9)["format"], 2021)

    def test_a_stream_outside_the_mini_stream(self):
        s = text(MODERN) + b"\0" * 6000
        self.assertEqual(rf.info(self.file("a.rvt", compound(s)))["format"], 2021)

    def test_size_and_time_are_those_of_the_file(self):
        p = self.file("a.rvt", compound(text(MODERN)))
        r, st = rf.info(p), os.stat(p)
        self.assertEqual((r["size"], r["mtime_ns"]), (st.st_size, st.st_mtime_ns))

    def bad(self, data):
        r = rf.info(self.file("a.rvt", data))
        self.assertIsNone(r["format"])
        self.assertTrue(r["error"], r)

    def test_not_a_compound_file(self):
        self.bad(b"PK\x03\x04" * 400)
        self.bad(b"")

    def test_a_compound_file_without_the_stream(self):
        self.bad(compound(text(MODERN), name="WordDocument"))

    def test_loops_and_cut_files_end(self):
        self.bad(compound(text(MODERN), loop=True))
        self.bad(compound(text(MODERN) + b"\0" * 6000, loop=True))
        self.bad(compound(text(MODERN), cut=5000))

    def test_a_difat_that_points_at_itself_ends(self):
        d = bytearray(compound(text(MODERN)))
        d[68:76] = struct.pack("<II", 0, 0xFFFFFFFF)   # first DIFAT sector: 0, which loops; a count that does not help
        d[4096:8192] = struct.pack("<1024I", *([0] * 1024))
        self.bad(bytes(d))

    def test_a_missing_file(self):
        self.assertTrue(rf.info(os.path.join(self.d, "none.rvt"))["error"])

    def test_cli(self):
        p = self.file("a.rvt", compound(text(MODERN)))
        o = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "rvtfile.py"), "info", p], capture_output=True, text=True)
        self.assertEqual(o.returncode, 0)
        self.assertEqual(json.loads(o.stdout)["format"], 2021)
        o = subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "rvtfile.py"), "info", self.file("b.rvt", b"x")], capture_output=True, text=True)
        self.assertEqual(o.returncode, 1)
        self.assertEqual(json.loads(o.stdout)["error"], "not a Revit file")


class WinPath(Tmp):
    def bottle(self):
        b = os.path.join(self.d, "b")
        os.makedirs(os.path.join(b, "dosdevices"))
        os.makedirs(os.path.join(b, "drive_c"))
        self.drive = os.path.join(self.d, "cloud")
        os.makedirs(self.drive)
        for n, t in (("c:", "../drive_c"), ("g:", self.drive), ("z:", "/"), ("com1", "/dev/null")):
            os.symlink(t, os.path.join(b, "dosdevices", n))
        return b

    def test_z_for_a_mac_file(self):
        b = self.bottle()
        p = self.file("\u041f 1.rvt", b"x")
        self.assertEqual(rf.winpath(b, p), "Z:" + p.replace("/", "\\"))

    def test_the_longest_drive_wins(self):
        b = self.bottle()
        p = os.path.join(self.drive, "a b.rvt")
        open(p, "w").close()
        self.assertEqual(rf.winpath(b, p), "G:\\a b.rvt")

    def test_a_backslash_is_refused_it_would_reach_another_file(self):
        b = self.bottle()
        os.makedirs(os.path.join(self.d, "a"))
        self.file("a/b.rvt", b"old")
        p = self.file("a\\b.rvt", b"new")
        with self.assertRaises(rf.Bad):
            rf.winpath(b, p)

    def test_refused_names(self):
        b = self.bottle()
        for n in ('q".rvt', "a:b.rvt", "a|b.rvt", "a?.rvt", "a*.rvt", "a<b.rvt", "x\ty.rvt"):
            with self.assertRaises(rf.Bad, msg=n):
                rf.winpath(b, self.file(n, b"x"))
        os.makedirs(os.path.join(self.d, "folder."))
        with self.assertRaises(rf.Bad):
            rf.winpath(b, self.file("folder./a.rvt", b"x"))


class Copy(Tmp):
    def test_beside_the_file_and_numbered(self):
        p = self.file("Tower.0001.rvt", b"data")
        a, b = rf.copy(p, 2027), rf.copy(p, 2027)
        self.assertEqual(os.path.basename(a), "Tower.0001 (Revit 2027).rvt")
        self.assertEqual(os.path.basename(b), "Tower.0001 (Revit 2027 2).rvt")
        for x in (a, b):
            with open(x, "rb") as f:
                self.assertEqual(f.read(), b"data")

    def test_a_link_in_the_way_is_not_followed(self):
        p = self.file("a.rvt", b"data")
        victim = self.file("victim", b"keep")
        os.symlink(victim, os.path.join(self.d, "a (Revit 2027).rvt"))
        self.assertEqual(os.path.basename(rf.copy(p, 2027)), "a (Revit 2027 2).rvt")
        with open(victim, "rb") as f:
            self.assertEqual(f.read(), b"keep")

    def test_runs_at_the_same_time_get_their_own_copy(self):
        p = self.file("a.rvt", b"data" * 1000)
        got = []
        ts = [threading.Thread(target=lambda: got.append(rf.copy(p, 2027))) for _ in range(6)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(len(set(got)), 6)
        self.assertEqual([n for n in os.listdir(self.d) if n.endswith(".tmp")], [])

    def test_a_read_only_folder(self):
        p = self.file("a.rvt", b"data")
        os.chmod(self.d, 0o555)
        self.addCleanup(os.chmod, self.d, 0o755)
        with self.assertRaises(rf.Bad):
            rf.copy(p, 2027)


if __name__ == "__main__":
    unittest.main()
