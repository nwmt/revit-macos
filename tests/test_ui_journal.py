# SPDX-License-Identifier: MIT
"""tools/ui_journal.py and tools/ui_commands.py against files made here. Run with the other unit tests."""
import os, shutil, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import ui_commands  # noqa: E402
import ui_journal  # noqa: E402

BUILD = "20990101_0101"


def cmd(label, cid, text="Something"):
    return ('  Jrn.Command "%s"  , "%s , %s" \n' % (label, text, cid)).encode()


class Tmp(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)

    def write(self, name, data, mode="wb"):
        p = os.path.join(self.d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, mode) as f:
            f.write(data)
        return p


class Reader(Tmp):
    def test_a_command_line(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_WALL", "Create a wall"))
        got = ui_journal.Reader(p).read()
        self.assertEqual([(r.label, r.command) for r in got], [("Internal", "ID_FAKE_WALL")])

    def test_an_empty_description(self):
        p = self.write("j", b'  Jrn.Command "Internal"  , " , ID_FAKE_DIALOG" \n')
        self.assertEqual(ui_journal.Reader(p).read()[0].command, "ID_FAKE_DIALOG")

    def test_the_id_is_taken_whole(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_WALL"))
        self.assertNotEqual(ui_journal.Reader(p).read()[0].command, "ID_FAKE")

    def test_a_description_with_a_comma_keeps_the_last_field(self):
        p = self.write("j", cmd("Ribbon", "ID_FAKE_B", "One, two , ID_FAKE_A and more"))
        self.assertEqual(ui_journal.Reader(p).read()[0].command, "ID_FAKE_B")

    def test_other_lines_are_skipped(self):
        p = self.write("j", b"' 0:< text\n  Jrn.MouseMove 0, 1, 2\n" + cmd("Internal", "ID_FAKE_A") + b"\xff\xfe\x00bad\n")
        self.assertEqual(len(ui_journal.Reader(p).read()), 1)

    def test_a_line_without_its_end_waits(self):
        whole = cmd("Internal", "ID_FAKE_A")
        p = self.write("j", whole[:20])
        r = ui_journal.Reader(p)
        self.assertEqual(r.read(), [])
        self.write("j", whole[20:], "ab")
        self.assertEqual([x.command for x in r.read()], ["ID_FAKE_A"])
        self.assertEqual(r.read(), [])

    def test_only_what_is_new(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_A"))
        r = ui_journal.Reader(p)
        r.read()
        self.write("j", cmd("Internal", "ID_FAKE_B"), "ab")
        self.assertEqual([x.command for x in r.read()], ["ID_FAKE_B"])

    def test_a_resumed_reader_starts_at_its_offset(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_A"))
        r = ui_journal.Reader(p)
        r.read()
        self.write("j", cmd("Internal", "ID_FAKE_B"), "ab")
        again = ui_journal.Reader(p, offset=r.offset, identity=r.identity)
        self.assertEqual([x.command for x in again.read()], ["ID_FAKE_B"])

    def test_a_file_gone_is_lost(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_A"))
        r = ui_journal.Reader(p)
        r.read()
        os.remove(p)
        self.assertEqual(r.read(), [])
        self.assertTrue(r.lost)

    def test_a_shorter_file_is_lost(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_A") * 3)
        r = ui_journal.Reader(p)
        r.read()
        self.write("j", cmd("Internal", "ID_FAKE_B"))
        self.assertEqual(r.read(), [])
        self.assertTrue(r.lost)

    def replaced(self, extra):
        p = self.write("j", cmd("Internal", "ID_FAKE_A"))
        r = ui_journal.Reader(p)
        r.read()
        other = self.write("other", cmd("Internal", "ID_FAKE_A") + extra)
        os.replace(other, p)
        self.assertEqual(r.read(), [])
        self.assertTrue(r.lost)

    def test_a_file_replaced_with_one_of_the_same_length_is_lost(self):
        self.replaced(b"")

    def test_a_file_replaced_with_a_longer_one_is_lost(self):
        self.replaced(cmd("Internal", "ID_FAKE_B"))

    def test_a_resumed_reader_notices_a_replaced_file(self):
        p = self.write("j", cmd("Internal", "ID_FAKE_A"))
        r = ui_journal.Reader(p)
        r.read()
        os.replace(self.write("other", cmd("Internal", "ID_FAKE_B") * 3), p)
        again = ui_journal.Reader(p, offset=r.offset, identity=r.identity)
        self.assertEqual(again.read(), [])
        self.assertTrue(again.lost)


class Build(Tmp):
    def test_the_build_line(self):
        p = self.write("j", b"' Comment\n' Build: " + BUILD.encode() + b"(x64)\n")
        self.assertEqual(ui_journal.build(p), BUILD)

    def test_no_build_line(self):
        self.assertIsNone(ui_journal.build(self.write("j", b"' Comment\n")))

    def test_past_the_first_forty_lines(self):
        self.assertIsNone(ui_journal.build(self.write("j", b"' x\n" * 40 + b"' Build: " + BUILD.encode() + b"\n")))

    def test_no_file(self):
        self.assertIsNone(ui_journal.build(os.path.join(self.d, "none")))


class Find(Tmp):
    def journal(self, name, mtime):
        p = self.write(os.path.join("drive_c", "users", "crossover", "AppData", "Local", "Autodesk", "Revit",
                                    "Autodesk Revit 2099", "Journals", name), b"x\n")
        os.utime(p, (mtime, mtime))
        return p

    def test_the_newest_of_this_run(self):
        self.journal("journal.0001.txt", 1000)
        new = self.journal("journal.0002.txt", 2000)
        self.assertEqual(ui_journal.find(self.d, 2099, 1500), new)

    def test_nothing_of_this_run(self):
        self.journal("journal.0001.txt", 1000)
        self.assertIsNone(ui_journal.find(self.d, 2099, 1500))


class Table(Tmp):
    def table(self, body, build=BUILD):
        return self.write(os.path.relpath(ui_commands.path(self.d, build), self.d), body.encode())

    def test_path(self):
        self.assertTrue(ui_commands.path(self.d, BUILD).endswith(
            os.path.join("AppData", "Local", "revit-macos", "ui-commands-%s.tsv" % BUILD)))

    def test_number(self):
        self.table("# %s\nID_FAKE_WALL\t1001\nID_FAKE_DOOR\t1002\n" % BUILD)
        t = ui_commands.load(self.d, BUILD)
        self.assertEqual(t.number("ID_FAKE_DOOR"), 1002)
        self.assertIsNone(t.number("ID_FAKE_NONE"))

    def test_status_ready(self):
        self.table("# %s\nID_FAKE_WALL\t1001\n" % BUILD)
        self.assertEqual(ui_commands.status(self.d, BUILD), "ready")

    def test_status_missing(self):
        self.assertEqual(ui_commands.status(self.d, BUILD), "missing")
        self.assertIsNone(ui_commands.load(self.d, BUILD))

    def test_status_error_has_the_reason(self):
        p = ui_commands.path(self.d, BUILD)
        self.write(os.path.relpath(p[:-3] + "error", self.d), b"ShortcutsHelper is gone")
        self.assertEqual(ui_commands.status(self.d, BUILD), "error")
        self.assertIn("ShortcutsHelper", ui_commands.error_text(self.d, BUILD))

    def bad(self, body):
        self.table(body)
        self.assertIsNone(ui_commands.load(self.d, BUILD))
        self.assertEqual(ui_commands.status(self.d, BUILD), "error")

    def test_another_build_in_the_header(self):
        self.bad("# 19990101_0101\nID_FAKE_WALL\t1001\n")

    def test_a_duplicate_number(self):
        self.bad("# %s\nID_FAKE_A\t1001\nID_FAKE_B\t1001\n" % BUILD)

    def test_an_empty_table(self):
        self.bad("# %s\n" % BUILD)

    def test_a_broken_line(self):
        self.bad("# %s\nID_FAKE_A 1001\n" % BUILD)

    def test_a_number_out_of_range(self):
        self.bad("# %s\nID_FAKE_A\t70000\n" % BUILD)

    def test_search_by_words_in_any_case(self):
        self.table("# %s\nID_FAKE_WALL_TOOL\t1001\nID_FAKE_DOOR\t1002\nID_WALL_SWEEP\t1003\n" % BUILD)
        t = ui_commands.load(self.d, BUILD)
        self.assertEqual(t.search("wall tool"), ["ID_FAKE_WALL_TOOL"])
        self.assertEqual(sorted(t.search("WALL")), ["ID_FAKE_WALL_TOOL", "ID_WALL_SWEEP"])

    def test_search_has_a_limit(self):
        self.table("# %s\n%s" % (BUILD, "".join("ID_FAKE_%d\t%d\n" % (i, 1000 + i) for i in range(60))))
        self.assertEqual(len(ui_commands.load(self.d, BUILD).search("fake")), 50)


if __name__ == "__main__":
    unittest.main()
