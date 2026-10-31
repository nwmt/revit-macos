# SPDX-License-Identifier: MIT
"""tools/ui_mac.py without Quartz: choosing a window, coordinates, waiting for a person. Run with the other unit tests."""
import os, shutil, struct, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import ui_mac  # noqa: E402


def win(number, pid, name="Autodesk Revit 2099 - [a.rvt]", layer=0, w=100, h=100):
    return {"number": number, "pid": pid, "name": name, "layer": layer, "w": w, "h": h}


class Pick(unittest.TestCase):
    def test_the_process_decides_not_the_title(self):
        wins = [win(1, 10), win(2, 20)]
        self.assertEqual(ui_mac.pick(wins, 20, "Autodesk Revit"), 2)

    def test_the_title_chooses_inside_the_process(self):
        wins = [win(1, 10), win(2, 10, "Virtual Memory - High Usage")]
        self.assertEqual(ui_mac.pick(wins, 10, "Virtual Memory"), 2)

    def test_other_layers_do_not_count(self):
        self.assertIsNone(ui_mac.pick([win(1, 10, layer=25)], 10, "Autodesk Revit"))

    def test_nothing(self):
        self.assertIsNone(ui_mac.pick([win(1, 11)], 10, "Autodesk Revit"))

    def test_the_biggest_of_two(self):
        wins = [win(1, 10, w=10, h=10), win(2, 10, w=900, h=900)]
        self.assertEqual(ui_mac.pick(wins, 10, "Autodesk Revit"), 2)


class ToWine(unittest.TestCase):
    RECT = (100, 200, 3100, 2200)

    def test_retina(self):
        self.assertEqual(ui_mac.to_wine(10, 20, 3000, 2000, self.RECT), (110, 220))

    def test_a_smaller_picture(self):
        self.assertEqual(ui_mac.to_wine(150, 100, 1500, 1000, self.RECT), (400, 400))

    def test_a_scale_of_one_and_a_half(self):
        self.assertEqual(ui_mac.to_wine(100, 100, 2000, 1333, self.RECT), (250, 350))

    def test_outside_the_picture(self):
        for x, y in ((-1, 0), (0, -1), (3000, 0), (0, 2000)):
            with self.assertRaises(ValueError):
                ui_mac.to_wine(x, y, 3000, 2000, self.RECT)


class Quiet(unittest.TestCase):
    def setUp(self):
        self.t = 0.0

    def clock(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def test_quiet_now(self):
        self.assertTrue(ui_mac.wait_user_quiet(lambda: 5.0, lambda: False, self.sleep, self.clock))
        self.assertEqual(self.t, 0)

    def test_a_person_stops(self):
        self.assertTrue(ui_mac.wait_user_quiet(lambda: self.t, lambda: False, self.sleep, self.clock))
        self.assertGreaterEqual(self.t, 3)

    def test_a_person_goes_on(self):
        self.assertFalse(ui_mac.wait_user_quiet(lambda: 0.0, lambda: False, self.sleep, self.clock))
        self.assertGreaterEqual(self.t, 10)

    def test_a_held_button_counts_as_work(self):
        self.assertFalse(ui_mac.wait_user_quiet(lambda: 60.0, lambda: True, self.sleep, self.clock))


class Picture(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)

    def test_size_of_a_png(self):
        p = os.path.join(self.d, "a.png")
        with open(p, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 640, 480) + b"\x08\x06\x00\x00\x00")
        self.assertEqual(ui_mac.png_size(p), (640, 480))

    def test_no_picture_names_the_permission(self):
        with self.assertRaises(ui_mac.NoPicture) as e:
            ui_mac.screenshot(1, os.path.join(self.d, "none.png"), run=lambda *a: None)
        self.assertIn("Screen Recording", str(e.exception))


if __name__ == "__main__":
    unittest.main()
