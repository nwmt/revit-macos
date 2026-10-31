import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import recent


def ini(lines, enc="utf-16"):
    return "\r\n".join(lines).encode(enc)


class Parse(unittest.TestCase):
    def test_utf16_with_a_mark(self):
        self.assertEqual(recent.parse_ini(ini(["[Other]", "File1=no", "[Recent File List]", r"File1=C:\a.rvt"])), [r"C:\a.rvt"])

    def test_utf8(self):
        self.assertEqual(recent.parse_ini(ini(["[Recent File List]", "File1=C:\\\u00e9.rvt"], "utf-8")), ["C:\\\u00e9.rvt"])

    def test_by_number_and_once(self):
        lines = ["[Recent File List]"] + [f"File{n}=C:\\{n}.rvt" for n in (10, 2, 9)] + [r"File11=c:\2.RVT", "[Next]", "File1=C:\\x.rvt"]
        self.assertEqual(recent.parse_ini(ini(lines)), [r"C:\2.rvt", r"C:\9.rvt", r"C:\10.rvt"])

    def test_no_section(self):
        self.assertEqual(recent.parse_ini(ini(["[Other]"])), [])


class Paths(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.addCleanup(self.d.cleanup)
        self.b = self.d.name
        os.makedirs(os.path.join(self.b, "dosdevices"))
        os.symlink("../drive_g", os.path.join(self.b, "dosdevices", "g:"))   # a link to nothing still counts

    def test_c_and_g_are_text(self):
        self.assertEqual(recent.to_mac(self.b, r"C:\users\crossover\Documents\a.rvt"),
                         os.path.join(self.b, "drive_c/users/crossover/Documents/a.rvt"))
        self.assertEqual(recent.to_mac(self.b, r"G:\Shared drives\T\a.rvt"), os.path.join(self.b, "dosdevices/g:/Shared drives/T/a.rvt"))

    def test_no_path_for_what_the_bottle_has_not(self):
        self.assertIsNone(recent.to_mac(self.b, r"H:\a.rvt"))
        self.assertIsNone(recent.to_mac(self.b, r"\\server\share\a.rvt"))

    def test_where_has_no_user_or_whole_path(self):
        self.assertEqual(recent.where(r"C:\users\crossover\Documents\Projects\a.rvt"), "Documents › Projects")
        self.assertEqual(recent.where(r"G:\Shared drives\T\a.rvt"), "G: › Shared drives › T")
        self.assertEqual(recent.where(r"C:\Program Files\Samples\a.rvt"), "Samples")
        self.assertEqual(recent.where(r"\\server\share\a.rvt"), "share")
        self.assertEqual(recent.where(r"Z:\Users\someone\Documents\Work\a.rvt"), "Work")

    def write(self, lines):
        d = os.path.join(self.b, "drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit 2027")
        os.makedirs(d)
        with open(os.path.join(d, "Revit.ini"), "wb") as f:
            f.write(ini(lines))

    def test_files_keeps_revit_kinds(self):
        self.write(["[Recent File List]", r"File1=G:\T\a.RVT", r"File2=C:\b.pdf", r"File3=C:\c.rfa", r"File4=C:\noext"])
        self.assertEqual([(f["name"], f["kind"]) for f in recent.files(self.b, "2027")], [("a.RVT", "rvt"), ("c.rfa", "rfa")])

    def test_no_ini(self):
        self.assertEqual(recent.files(self.b, "2027"), [])

    def test_a_recent_file_is_never_touched(self):
        self.write(["[Recent File List]", r"File1=G:\T\a.rvt", r"File2=C:\users\crossover\Documents\b.rvt"])
        def no(*a, **k):
            raise AssertionError(f"touched {a}")
        with mock.patch("os.stat", no), mock.patch("os.path.exists", no), mock.patch("os.path.realpath", no), mock.patch("os.path.isfile", no):
            with mock.patch("os.path.lexists", lambda p: p.endswith("g:")):
                self.assertEqual(len(recent.files(self.b, "2027")), 2)


if __name__ == "__main__":
    unittest.main()
