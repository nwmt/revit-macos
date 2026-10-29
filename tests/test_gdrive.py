# SPDX-License-Identifier: MIT
"""Tests for tools/gdrive.py (the G: drive: Google Drive in a bottle). Run: python3 -I -m unittest tests.test_gdrive
A fake home with Library/CloudStorage/GoogleDrive-<account> and a fake bottle live in a temporary folder; nothing
touches the real Google Drive."""
import importlib.util, io, json, os, subprocess, sys, tempfile, unicodedata, unittest

TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools")
EMAIL = "someone@example.com"
ROLES = ("My Drive", "Shared drives", "Other computers")


def load():
    spec = importlib.util.spec_from_file_location("gdrive", os.path.join(TOOLS, "gdrive.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


g = load()


class Fake(unittest.TestCase):
    """A home with Google Drive accounts and a bottle; HOME points at the fake home for the module and its runs."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.join(self.tmp.name, "home")
        self.cloud = os.path.join(self.home, "Library", "CloudStorage")
        os.makedirs(self.cloud)
        self.b = os.path.join(self.tmp.name, "bottle")
        os.makedirs(os.path.join(self.b, "dosdevices"))
        os.makedirs(os.path.join(self.b, "drive_c"))
        os.symlink("../drive_c", os.path.join(self.b, "dosdevices", "c:"))
        self.old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.home

    def tearDown(self):
        if self.old_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.old_home
        self.tmp.cleanup()

    def account(self, email=EMAIL, roles=ROLES):
        a = os.path.join(self.cloud, "GoogleDrive-" + email)
        for r in roles:
            os.makedirs(os.path.join(a, r), exist_ok=True)
        return a

    def settings(self, text):
        d = os.path.join(self.b, "drive_c", "Program Files", "revit-macos")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "gdrive"), "w", encoding="utf-8") as f:
            f.write(text)

    def mapping(self, account, names=ROLES, g_text="../drive_g", marker=True):
        """A G: as apply leaves it, built by hand."""
        d = os.path.join(self.b, "drive_g")
        os.makedirs(d)
        if marker:
            open(os.path.join(d, g.MARK), "w").write("1\n")
        for n in names:
            role = n if n in ROLES else {"\u041c\u043e\u0439 \u0434\u0438\u0441\u043a": "My Drive", "\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438": "Shared drives",
                                         "\u041a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b": "Other computers"}[n]
            os.symlink(os.path.join(account, role), os.path.join(d, n))
        os.symlink(g_text, os.path.join(self.b, "dosdevices", "g:"))

    def run_tool(self, *args, env=None):
        e = dict(os.environ, HOME=self.home, **(env or {}))
        return subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "gdrive.py"), *args],
                              capture_output=True, text=True, env=e)


class Names(unittest.TestCase):
    def ok(self, value):
        return g.parse_names(value)

    def bad(self, value, pair, word):
        with self.assertRaises(g.NamesError) as c:
            g.parse_names(value)
        self.assertEqual(c.exception.pair, pair)
        self.assertIn(word, c.exception.reason)
        return c.exception

    def test_default_is_english_only(self):
        self.assertEqual(self.ok(""), {r: [] for r in ROLES})
        self.assertEqual(self.ok("en"), {r: [] for r in ROLES})

    def test_ru_preset(self):
        self.assertEqual(self.ok("ru"), {"My Drive": ["\u041c\u043e\u0439 \u0434\u0438\u0441\u043a"], "Shared drives": ["\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438"],
                                         "Other computers": ["\u041a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b"]})

    def test_own_pairs_and_preset_override(self):
        n = self.ok("ru;Other computers=\u041c\u043e\u0438 \u043a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b;My Drive=\u0414\u0438\u0441\u043a")
        self.assertEqual(n["Other computers"], ["\u041c\u043e\u0438 \u043a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b"])
        self.assertEqual(n["My Drive"], ["\u0414\u0438\u0441\u043a"])
        self.assertEqual(n["Shared drives"], ["\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438"])
        self.assertEqual(self.ok("Shared drives=A;Shared drives=B")["Shared drives"], ["A", "B"])

    def test_nfc(self):
        self.assertEqual(self.ok("My Drive=Cafe\u0301")["My Drive"], ["Caf\u00e9"])

    def test_bad_names(self):
        self.bad("My Drive=", 1, "empty")
        self.bad("ru;My Drive=a\\b", 2, "character")
        for ch in '/:*?"<>|@':
            self.bad("My Drive=a" + ch + "b", 1, "character")
        self.bad("My Drive=a\nb", 1, "character")
        self.bad("My Drive=a\tb", 1, "character")
        self.bad("My Drive=x.", 1, "end")
        self.bad("My Drive=x ", 1, "end")
        self.bad("My Drive=..", 1, "end")
        self.bad("My Drive=CON", 1, "reserved")
        self.bad("My Drive=com1.txt", 1, "reserved")
        self.bad("My Drive=" + g.MARK, 1, "reserved")
        self.bad("Trash=x", 1, "folder")
        self.bad("de", 1, "preset")
        self.bad("ru;en", 2, "first")

    def test_duplicates_in_the_whole_set(self):
        self.bad("Shared drives=my drive", 1, "same")
        self.bad("My Drive=Caf\u00e9;Shared drives=CAFE\u0301", 2, "same")
        self.bad("ru;Shared drives=\u043c\u043e\u0439 \u0414\u0418\u0421\u041a", 2, "same")

    def test_error_text_has_no_value(self):
        e = self.bad("My Drive=" + EMAIL, 1, "character")
        self.assertNotIn(EMAIL, str(e))


class Accounts(Fake):
    def test_counts(self):
        self.assertEqual(g.accounts(), [])
        self.account()
        self.assertEqual(len(g.accounts()), 1)
        self.account("other@example.com")
        self.assertEqual(len(g.accounts()), 2)

    def test_a_file_or_link_is_not_an_account(self):
        open(os.path.join(self.cloud, "GoogleDrive-x@example.com"), "w").close()
        os.symlink(self.tmp.name, os.path.join(self.cloud, "GoogleDrive-y@example.com"))
        os.makedirs(os.path.join(self.cloud, "OneDrive-z"))
        self.assertEqual(g.accounts(), [])


class State(Fake):
    def st(self):
        return g.state(self.b)

    def test_old_bottle(self):
        self.account()
        s = self.st()
        self.assertEqual((s["mode"], s["mapping"], s["accounts"], s["settings"]), ("auto", "none", "one", False))

    def test_ok_and_names(self):
        a = self.account()
        self.settings("mode=auto\nnames=ru\n")
        self.mapping(a, ROLES + ("\u041c\u043e\u0439 \u0434\u0438\u0441\u043a", "\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438", "\u041a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b"))
        s = self.st()
        self.assertEqual((s["mapping"], s["names"], s["settings"]), ("ok", 3, True))

    def test_stale_when_names_differ(self):
        a = self.account()
        self.settings("mode=auto\nnames=ru\n")
        self.mapping(a)
        self.assertEqual(self.st()["mapping"], "stale")

    def test_stale_when_drive_g_is_gone(self):
        self.account()
        os.symlink("../drive_g", os.path.join(self.b, "dosdevices", "g:"))
        self.assertEqual(self.st()["mapping"], "stale")

    def test_account_missing(self):
        a = self.account()
        self.mapping(a)
        os.rename(a, a + "-gone")
        s = self.st()
        self.assertEqual((s["mapping"], s["accounts"]), ("account-missing", "one"))

    def test_several_keeps_ok(self):
        a = self.account()
        self.account("other@example.com")
        self.mapping(a)
        s = self.st()
        self.assertEqual((s["mapping"], s["accounts"]), ("ok", "several"))

    def test_chosen_account(self):
        a = self.account()
        b = self.account("other@example.com")
        self.settings("mode=other@example.com\nnames=en\n")
        self.mapping(a)
        s = self.st()
        self.assertEqual((s["mode"], s["mapping"]), ("account", "stale"))
        os.unlink(os.path.join(self.b, "dosdevices", "g:"))
        os.rename(os.path.join(self.b, "drive_g"), os.path.join(self.b, "x"))
        self.mapping(b)
        self.assertEqual(self.st()["mapping"], "ok")

    def test_foreign_letter(self):
        self.account()
        os.symlink("/Volumes/share", os.path.join(self.b, "dosdevices", "g:"))
        self.assertEqual(self.st()["mapping"], "foreign")

    def test_foreign_drive_g_without_letter(self):
        self.account()
        d = os.path.join(self.b, "drive_g")
        os.makedirs(d)
        open(os.path.join(d, "notes.txt"), "w").close()
        self.assertEqual(self.st()["mapping"], "foreign")

    def test_unmarked_drive_g_is_foreign(self):
        a = self.account()
        self.mapping(a, marker=False)
        self.assertEqual(self.st()["mapping"], "foreign")

    def test_drive_g_link_is_foreign(self):
        self.account()
        os.symlink(self.tmp.name, os.path.join(self.b, "drive_g"))
        self.assertEqual(self.st()["mapping"], "foreign")

    def test_off(self):
        self.account()
        self.settings("mode=off\nnames=en\n")
        s = self.st()
        self.assertEqual((s["mode"], s["mapping"]), ("off", "none"))

    def test_json_has_no_email(self):
        a = self.account()
        self.settings(f"mode={EMAIL}\nnames=ru\n")
        self.mapping(a, ROLES + ("\u041c\u043e\u0439 \u0434\u0438\u0441\u043a", "\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438", "\u041a\u043e\u043c\u043f\u044c\u044e\u0442\u0435\u0440\u044b"))
        r = self.run_tool("state", self.b)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout), {"mode": "account", "mapping": "ok", "accounts": "one", "names": 3,
                                                "settings": True})
        self.assertNotIn("example.com", r.stdout + r.stderr)


class SettingsThroughLinks(Fake):
    def test_a_linked_folder_is_not_read(self):
        out = os.path.join(self.tmp.name, "outside", "revit-macos")
        os.makedirs(out)
        with open(os.path.join(out, "gdrive"), "w") as f:
            f.write("mode=off\nnames=ru\n")
        pf = os.path.join(self.b, "drive_c", "Program Files")
        os.symlink(os.path.dirname(out), pf)
        self.assertIsNone(g.read_settings(self.b))
        os.unlink(pf)
        os.makedirs(pf)
        os.symlink(out, os.path.join(pf, "revit-macos"))
        self.assertIsNone(g.read_settings(self.b))
        os.unlink(os.path.join(pf, "revit-macos"))
        os.makedirs(os.path.join(pf, "revit-macos"))
        os.symlink(os.path.join(out, "gdrive"), os.path.join(pf, "revit-macos", "gdrive"))
        self.assertIsNone(g.read_settings(self.b))


class Advice(Fake):
    def adv(self, **kw):
        s = dict({"mode": "auto", "mapping": "none", "accounts": "one", "names": 0, "settings": False}, **kw)
        return g.advice(s, 2027)

    def test_table(self):
        self.assertEqual(self.adv(accounts="zero")[0], "info")
        self.assertIn("not found", self.adv(accounts="zero")[1])
        lvl, text = self.adv()
        self.assertEqual(lvl, "warn")
        self.assertIn("./revit set 2027 gdrive=auto", text)
        lvl, text = self.adv(settings=True, mapping="stale")
        self.assertIn("gdrive=again", text)
        self.assertIn("gdrive=<email>", self.adv(accounts="several")[1])
        lvl, text = self.adv(mapping="ok", accounts="several", names=3)
        self.assertEqual(lvl, "warn")
        self.assertIn("G: \u2192 Google Drive", text)
        self.assertIn("several", text)
        self.assertEqual(self.adv(mapping="ok", names=3), ("ok", "G: \u2192 Google Drive (3 more folder names)"))
        self.assertEqual(self.adv(mapping="ok"), ("ok", "G: \u2192 Google Drive"))
        self.assertIn("something else", self.adv(mapping="foreign")[1])
        self.assertIn("gone", self.adv(mapping="account-missing", settings=True)[1])
        self.assertEqual(self.adv(mode="off", settings=True), ("info", "G: off"))
        self.assertIn("gdrive=again", self.adv(mode="off", settings=True, mapping="ok")[1])
        self.assertIn("not on this Mac", self.adv(mode="account", settings=True, accounts="zero", mapping="none")[1])

    def test_no_email_anywhere(self):
        for kw in ({}, {"mode": "account", "settings": True}, {"mapping": "account-missing"}):
            self.assertNotIn("@example", self.adv(**kw)[1])


class Sanitize(Fake):
    def test_paths_and_emails(self):
        a = self.account()
        self.settings(f"mode={EMAIL}\nnames=en\n")
        t = g.sanitize(f"error: {a}/My Drive/x: denied; account {EMAIL}; other@example.com", self.b)
        self.assertNotIn("example.com", t)
        self.assertIn("GoogleDrive-<account>/My Drive/x", t)

    def test_filter(self):
        a = self.account()
        r = subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "gdrive.py"), "sanitize", self.b],
                           input=f"{a}/Shared drives\n{EMAIL}\n", capture_output=True, text=True,
                           env=dict(os.environ, HOME=self.home))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("example.com", r.stdout)


def tree(root):
    """Every path under root with its kind and, for links, the target; for files, the content."""
    out = {}
    for dp, dns, fns in os.walk(root, followlinks=False):
        for n in dns + fns:
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                out[rel] = ("link", os.readlink(p))
            elif os.path.isdir(p):
                out[rel] = ("dir",)
            else:
                out[rel] = ("file", open(p, "rb").read())
    return out


POINTS = ["mkdir Program Files", "mkdir revit-macos", "settings tmp", "settings", "restore old", "mkdir new", "mark",
          "link", "old aside", "publish", "g link", "unlink link", "unlink mark", "rmdir drive_g.old",
          "rmdir drive_g.new", "unlink g", "off rename"]
RU = "ru"


class Apply(Fake):
    def setUp(self):
        super().setUp()
        self.bait = os.path.join(self.tmp.name, "bait")
        os.makedirs(os.path.join(self.bait, "sub"))
        open(os.path.join(self.bait, "keep.txt"), "w").write("user file")
        os.symlink("/", os.path.join(self.bait, "a link"))
        self.bait_before = tree(self.bait)

    def tearDown(self):
        self.assertEqual(tree(self.bait), self.bait_before, "the bait folder changed")
        super().tearDown()

    def apply(self, *args, env=None):
        return self.run_tool("apply", self.b, *args, env=env)

    def st(self):
        return g.state(self.b)

    def test_states(self):
        a = self.account()
        r = self.apply()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.st()["mapping"], "ok")
        self.assertEqual(os.readlink(os.path.join(self.b, "dosdevices", "g:")), "../drive_g")
        self.assertEqual(os.readlink(os.path.join(self.b, "drive_g", "My Drive")), os.path.join(a, "My Drive"))
        r = self.apply("--names", RU)
        self.assertEqual(r.returncode, 0, r.stderr)
        s = self.st()
        self.assertEqual((s["mapping"], s["names"]), ("ok", 3))
        self.assertTrue(os.path.islink(os.path.join(self.b, "drive_g", "\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438")))
        before = tree(self.b)
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(tree(self.b), before, "a second run changed the bottle")
        self.assertEqual(self.apply("--mode", "off").returncode, 0)
        self.assertEqual(self.st()["mapping"], "none")
        self.assertFalse(os.path.lexists(os.path.join(self.b, "drive_g")))
        self.assertTrue(os.path.isdir(os.path.join(a, "My Drive")), "Google Drive changed")

    def test_no_account_and_several_keep_g(self):
        r = self.apply()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.st()["mapping"], "none")
        a = self.account()
        self.apply()
        self.account("other@example.com")
        before = tree(self.b)
        r = self.apply()
        self.assertEqual(r.returncode, 0)
        self.assertIn("several", r.stdout)
        self.assertEqual({k: v for k, v in tree(self.b).items() if "gdrive" not in k},
                         {k: v for k, v in before.items() if "gdrive" not in k})

    def test_chosen_account_and_again(self):
        self.account()
        b = self.account("other@example.com")
        r = self.apply("--mode", "other@example.com", "--names", RU)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(os.readlink(os.path.join(self.b, "drive_g", "My Drive")), os.path.join(b, "My Drive"))
        r = self.apply("--mode", "again")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(g.read_settings(self.b), {"mode": "other@example.com", "names": RU})
        self.assertNotIn("example.com", r.stdout + r.stderr)
        self.assertEqual(self.apply("--mode", "again", "--names", "en").returncode, 2)

    def test_missing_account_changes_nothing(self):
        self.account()
        before = tree(self.b)
        r = self.apply("--mode", "nobody@example.com")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(tree(self.b), before)
        self.assertNotIn("example.com", r.stdout + r.stderr)

    def test_foreign_g_and_drive_g(self):
        self.account()
        os.symlink(self.bait, os.path.join(self.b, "dosdevices", "g:"))
        before = tree(self.b)
        self.assertEqual(self.apply().returncode, 1)
        self.assertEqual(self.apply("--mode", "off").returncode, 1)
        self.assertEqual(tree(self.b), before)

    def test_foreign_drive_g_without_letter(self):
        self.account()
        d = os.path.join(self.b, "drive_g")
        os.makedirs(d)
        os.symlink(self.bait, os.path.join(d, "a link of the user"))
        open(os.path.join(d, "notes.txt"), "w").write("x")
        before = tree(self.b)
        self.assertEqual(self.apply().returncode, 1)
        self.assertEqual(tree(self.b), before)

    def test_bait_links_in_place_of_our_paths(self):
        self.account()
        for name in ("drive_g", "drive_g.new", "drive_g.old"):
            p = os.path.join(self.b, name)
            os.symlink(self.bait, p)
            self.assertEqual(self.apply().returncode, 1, name)
            self.assertEqual(self.apply("--mode", "off").returncode, 1, name)
            os.unlink(p)
        pf = os.path.join(self.b, "drive_c", "Program Files")
        os.symlink(self.bait, pf)
        self.assertEqual(self.apply().returncode, 1)
        os.unlink(pf)
        os.makedirs(pf)
        os.symlink(self.bait, os.path.join(pf, "revit-macos"))
        self.assertEqual(self.apply().returncode, 1)
        os.unlink(os.path.join(pf, "revit-macos"))
        os.makedirs(os.path.join(pf, "revit-macos"))
        os.symlink(os.path.join(self.bait, "keep.txt"), os.path.join(pf, "revit-macos", "gdrive"))
        self.assertEqual(self.apply().returncode, 0)   # replaced: the link itself, not the file it points at
        self.assertFalse(os.path.islink(os.path.join(pf, "revit-macos", "gdrive")))
        d = os.path.join(self.b, "drive_g")
        os.makedirs(d, exist_ok=True)

    def test_a_mark_that_is_a_link_is_not_ours(self):
        a = self.account()
        self.apply()
        m = os.path.join(self.b, "drive_g", g.MARK)
        os.unlink(m)
        os.symlink(os.path.join(self.bait, "keep.txt"), m)
        self.assertEqual(self.apply("--mode", "off").returncode, 1)

    def test_no_settings_folder(self):
        self.account()
        self.assertFalse(os.path.exists(os.path.join(self.b, "drive_c", "Program Files")))
        self.assertEqual(self.apply().returncode, 0)
        self.assertEqual(g.read_settings(self.b), {"mode": "auto", "names": "en"})
        os.remove(os.path.join(self.b, *g.SETTINGS))
        os.rmdir(os.path.join(self.b, "drive_c", "Program Files", "revit-macos"))
        open(os.path.join(self.b, "drive_c", "Program Files", "revit-macos"), "w").close()
        self.assertEqual(self.apply().returncode, 1)

    # Each scenario makes the state its points need, runs apply, and lists the points that run reaches, in order.
    def fresh(self):
        self.account()
        return (), ["mkdir Program Files", "mkdir revit-macos", "settings tmp", "settings", "mkdir new", "mark", "link",
                    "publish", "g link"]

    def change(self):
        self.account()
        self.apply()
        return ("--names", RU), ["settings tmp", "settings", "mkdir new", "mark", "link", "old aside", "publish",
                                 "unlink link", "unlink mark", "rmdir drive_g.old"]

    def restore(self):   # cut short after the old G: was set aside: the next run puts it back
        self.account()
        self.apply()
        self.assertEqual(self.apply("--names", RU, env={"GDRIVE_TEST_STOP": "old aside"}).returncode, 9)
        return ("--mode", "again"), ["settings tmp", "settings", "restore old", "unlink link", "unlink mark",
                                     "rmdir drive_g.new"]

    def off(self):
        self.account()
        self.apply()
        return ("--mode", "off"), ["settings tmp", "settings", "unlink g", "off rename", "unlink link", "unlink mark",
                                   "rmdir drive_g.old"]

    def check_after(self, args, points, p):
        r = self.apply("--mode", "again")
        self.assertEqual(r.returncode, 0, r.stderr)
        # the setting is saved first: cut short before it is in place, "again" still means the one before
        saved = points.index(p) >= points.index("settings")
        want = "none" if args == ("--mode", "off") and saved else "ok"
        self.assertEqual(self.st()["mapping"], want)
        for left in ("drive_g.new", "drive_g.old"):
            self.assertFalse(os.path.lexists(os.path.join(self.b, left)), left)
        if want == "none":
            self.assertEqual(self.apply("--mode", "auto").returncode, 0)
            self.assertEqual(self.st()["mapping"], "ok")

    def test_every_point_is_reached(self):
        seen = set()
        for scenario in (self.fresh, self.change, self.restore, self.off):
            self.reset()
            seen.update(scenario()[1])
        self.assertEqual(seen, set(POINTS))

    def test_interrupted_at_every_point(self):
        for scenario in (self.fresh, self.change, self.restore, self.off):
            self.reset()
            n = len(scenario()[1])
            for k in range(n):
                with self.subTest(scenario=scenario.__name__, k=k):
                    self.reset()
                    args, points = scenario()
                    p = points[k]
                    cut = self.apply(*args, env={"GDRIVE_TEST_STOP": p})
                    self.assertEqual(cut.returncode, 9, f"{p} was not reached: {cut.stderr}")
                    self.check_after(args, points, p)

    def test_failure_at_every_point(self):
        for scenario in (self.fresh, self.change, self.restore, self.off):
            self.reset()
            n = len(scenario()[1])
            for k in range(n):
                with self.subTest(scenario=scenario.__name__, k=k):
                    self.reset()
                    args, points = scenario()
                    p = points[k]
                    r = self.apply(*args, env={"GDRIVE_TEST_FAIL": p})
                    self.assertEqual(r.returncode, 1, f"{p}: {r.stderr}")
                    self.assertNotIn("Traceback", r.stderr)
                    self.check_after(args, points, p)

    def test_swap_a_checked_folder_for_a_link(self):
        self.account()
        self.apply()
        d = os.path.join(self.b, "drive_g")
        cmd = f'mv "{d}.old" "{d}.moved" && ln -s "{self.bait}" "{d}.old"'
        r = self.apply("--names", RU, env={"GDRIVE_TEST_SWAP": "unlink link", "GDRIVE_TEST_SWAP_CMD": cmd})
        self.assertNotIn("Traceback", r.stderr)

    def reset(self):
        for n in os.listdir(self.cloud):
            p = os.path.join(self.cloud, n)
            for dp, dns, fns in os.walk(p, topdown=False):
                for x in fns:
                    os.unlink(os.path.join(dp, x))
                for x in dns:
                    q = os.path.join(dp, x)
                    os.unlink(q) if os.path.islink(q) else os.rmdir(q)
            os.rmdir(p)
        for n in ("drive_g", "drive_g.new", "drive_g.old"):
            p = os.path.join(self.b, n)
            if os.path.islink(p):
                os.unlink(p)
            elif os.path.isdir(p):
                for x in os.listdir(p):
                    os.unlink(os.path.join(p, x))
                os.rmdir(p)
        gl = os.path.join(self.b, "dosdevices", "g:")
        if os.path.lexists(gl):
            os.unlink(gl)
        pf = os.path.join(self.b, "drive_c", "Program Files")   # the setting and its folders, with any leftovers
        if os.path.isdir(pf) and not os.path.islink(pf):
            for dp, dns, fns in os.walk(pf, topdown=False):
                for x in fns:
                    os.unlink(os.path.join(dp, x))
                for x in dns:
                    os.rmdir(os.path.join(dp, x))
            os.rmdir(pf)


class Warm(Fake):
    def setUp(self):
        super().setUp()
        self.a = self.account()
        self.settings("mode=auto\nnames=ru\n")
        r = self.run_tool("apply", self.b)
        assert r.returncode == 0, r.stderr
        work = os.path.join(self.a, "Shared drives", "Team", "Work")
        for d in ("p1/sub", "p2", ".hidden"):
            os.makedirs(os.path.join(work, d))
        os.makedirs(os.path.join(self.a, "My Drive", "x"))
        os.makedirs(os.path.join(self.a, ".Trash", "old"))
        os.symlink(self.tmp.name, os.path.join(work, "a shortcut"))
        open(os.path.join(work, "file.rvt"), "w").close()

    def warm(self, folder):
        return self.run_tool("warm", self.b, folder, "2027")

    def count(self, r):
        return int(r.stdout.split(" folders listed")[0].split("\n")[-1])

    def test_windows_paths_and_names(self):
        r = self.warm("G:\\Shared drives\\Team\\Work")
        self.assertEqual((r.returncode, self.count(r)), (0, 5), r.stderr)   # Work, p1, p2, .hidden, p1/sub; no link
        ru = "G:\\\u041e\u0431\u0449\u0438\u0435 \u0434\u0438\u0441\u043a\u0438\\Team\\Work"
        self.assertEqual(self.count(self.warm(ru)), 5)
        self.assertEqual(self.count(self.warm("g:/shared DRIVES/Team/Work")), 5)

    def test_drive_root_skips_missing_folders_and_trash(self):
        os.rmdir(os.path.join(self.a, "Other computers"))
        r = self.warm("G:\\")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.count(r), 9)   # My Drive, x, Shared drives, Team, Work and its 4; no .Trash, no link

    def test_a_role_that_is_a_link_is_not_walked(self):
        outside = os.path.join(self.tmp.name, "outside")
        os.makedirs(os.path.join(outside, "a", "b"))
        os.rmdir(os.path.join(self.a, "Other computers"))
        os.symlink(outside, os.path.join(self.a, "Other computers"))
        r = self.warm("G:\\")
        self.assertEqual((r.returncode, self.count(r)), (0, 9), r.stderr)   # as without Other computers
        self.assertEqual(self.warm("G:\\Other computers").returncode, 1)

    def test_mac_path(self):
        r = self.warm(os.path.join(self.a, "Shared drives", "Team"))
        self.assertEqual((r.returncode, self.count(r)), (0, 6), r.stderr)

    def test_outside_and_missing(self):
        for f in ("G:\\Shared drives\\..\\..\\..", "G:\\Nowhere", self.tmp.name, "G:\\Shared drives\\Team\\Work\\a shortcut",
                  "G:\\Other computers\\none"):
            r = self.warm(f)
            self.assertEqual(r.returncode, 1, f)
            self.assertNotIn("example.com", r.stdout + r.stderr)

    def test_needs_g(self):
        self.run_tool("apply", self.b, "--mode", "off")
        r = self.warm("G:\\")
        self.assertEqual(r.returncode, 1)
        self.assertIn("G: off", r.stderr)

    def test_stops_when_google_drive_does_not_answer(self):
        real = g.os.scandir
        calls = []
        acc = os.path.realpath(self.a)
        for i in range(g.TIMEOUTS + 2):
            os.makedirs(os.path.join(self.a, "Shared drives", "Team", "Work", "more%d" % i))

        def fake(p):   # the bottle's own folders as they are; Google Drive answers once, then times out
            if not str(p).startswith(acc):
                return real(p)
            calls.append(p)
            if len(calls) > 1:
                raise TimeoutError(60, "Operation timed out")
            return real(p)
        g.os.scandir = fake
        out = io.StringIO()
        try:
            code = g.warm(self.b, "G:\\Shared drives\\Team\\Work", "2027", out=out)
        finally:
            g.os.scandir = real
        self.assertEqual(code, 1)
        self.assertIn("does not answer", out.getvalue())
        self.assertEqual(len(calls), 1 + g.TIMEOUTS)

    def test_counts_cloud_only_and_errors(self):
        out = io.StringIO()
        real = os.lstat
        work = os.path.join(self.a, "Shared drives", "Team", "Work")

        class St:
            def __init__(self, st, flags):
                self.st, self.st_flags = st, flags

            def __getattr__(self, n):
                return getattr(self.st, n)

        def fake(p, *a, **k):
            st = real(p, *a, **k)
            return St(st, g.SF_DATALESS) if p.endswith("p2") else st
        g.os.lstat = fake
        try:
            code = g.warm(self.b, work, "2027", out=out)
        finally:
            g.os.lstat = real
        self.assertEqual(code, 0)
        self.assertIn("5 folders listed, 1 were cloud-only", out.getvalue())
        os.chmod(os.path.join(work, "p2"), 0)
        try:
            out = io.StringIO()
            self.assertEqual(g.warm(self.b, work, "2027", out=out), 1)
            self.assertIn("1 folders could not be listed", out.getvalue())
        finally:
            os.chmod(os.path.join(work, "p2"), 0o755)


if __name__ == "__main__":
    unittest.main()
