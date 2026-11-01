"""tools/patches/python-mcp/*.patch against the pinned upstream archive of the MCP server for Revit (Python): they apply
in order, a second run sees them applied, and each fixes what it says on IronPython 2 (pyRevit 4.8, Revit 2020)."""
import ast
import glob
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCHES = sorted(glob.glob(os.path.join(ROOT, "tools", "patches", "python-mcp", "*.patch")))
COMMIT = "6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d"
URL = "https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python/archive/%s.tar.gz" % COMMIT
SHA = "6406be6574efe9519b34110ccf04d1499bb47f0e3fc36ba902a30b9575e1f0f6"


def read(path):
    with open(path) as f:
        return f.read()


def patch(cwd, p, *args):
    return subprocess.run(["patch", "-p1", "-s", "--forward"] + list(args) + ["-i", p], cwd=cwd,
                          capture_output=True, text=True)


class Patches(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        r = subprocess.run(["bash", os.path.join(ROOT, "tests", "fixtures.sh"), URL, SHA, "python-mcp-%s.tar.gz" % COMMIT[:7]],
                           capture_output=True, text=True)
        if r.returncode == 77:
            raise unittest.SkipTest("SKIP: no network for the pinned MCP server archive")
        if r.returncode != 0:
            raise AssertionError(r.stdout + r.stderr)
        cls.tmp = tempfile.mkdtemp()
        with tarfile.open(r.stdout.strip()) as t:   # the pinned archive (sha256 checked by fixtures.sh)
            try:
                t.extractall(cls.tmp, filter="data")
            except TypeError:   # Python before 3.12 (the system 3.9 in CI) has no filter
                t.extractall(cls.tmp)
        cls.src = os.path.join(cls.tmp, "mcp-server-for-revit-python-" + COMMIT)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def test_1_patches_apply_in_order(self):
        self.assertEqual([os.path.basename(p) for p in PATCHES],
                         ["01-code-execution-ipy2.patch", "02-views-unquote-ipy2.patch", "03-pairing-ioerror.patch",
                          "04-startup-error-file.patch", "05-model-info-truth.patch", "06-screen-view-and-review.patch"])
        for p in PATCHES:
            r = patch(self.src, p)
            self.assertEqual(r.returncode, 0, p + r.stdout + r.stderr)

    def test_2_second_run_sees_them_applied(self):
        for p in PATCHES:
            r = patch(self.src, p, "-R", "--dry-run")
            self.assertEqual(r.returncode, 0, p + r.stdout + r.stderr)

    def test_3_patched_files_parse(self):
        for f in ("revit_mcp/code_execution.py", "revit_mcp/views.py", "revit_mcp/pairing.py", "startup.py"):
            ast.parse(read(os.path.join(self.src, f)))

    def test_4_execute_code_has_no_closure(self):
        tree = ast.parse(read(os.path.join(self.src, "revit_mcp/code_execution.py")))
        fn = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "execute_code"][0]
        nested = [n for n in ast.walk(fn) if n is not fn and isinstance(n, (ast.Lambda, ast.FunctionDef,
                                                                          ast.GeneratorExp, ast.ListComp))]
        self.assertEqual(nested, [], "IronPython 2 refuses exec in a function that holds a closure")

    def test_5_views_unquote_on_ironpython(self):
        src = read(os.path.join(self.src, "revit_mcp/views.py"))
        self.assertIn('if sys.platform == "cli":', src)
        self.assertIn("Uri.UnescapeDataString", src)

    def test_6_pairing_catches_ioerror(self):
        src = read(os.path.join(self.src, "revit_mcp/pairing.py"))
        self.assertIn("except (IOError, OSError, ValueError, PairingError):", src)

    def test_7_startup_error_file(self):
        src = read(os.path.join(self.src, "startup.py"))
        self.assertIn("startup-error.txt", src)
        tree = ast.parse(src)
        tries = [n for n in tree.body if isinstance(n, ast.Try)]
        self.assertTrue(tries and any(isinstance(c, ast.Expr) and getattr(c.value, "func", None) is not None
                                      and getattr(c.value.func, "id", "") == "register_routes"
                                      for c in tries[-1].body), "register_routes() is not inside a try")

    def test_8_model_info_counts_links_and_warnings(self):
        src = read(os.path.join(self.src, "revit_mcp", "model_info.py"))
        self.assertIn("DB.FailureSeverity.Error", src)
        self.assertIn("OfClass(DB.RevitLinkInstance)", src)
        self.assertNotIn("get_linked_model_instances", src)

    def test_9_cut_list_keeps_its_elements(self):
        self.assertIn('"message" in response and not response.get("truncated")', read(os.path.join(self.src, "tools", "utils.py")))

    def test_a_tools_follow_the_view_on_screen(self):
        views = read(os.path.join(self.src, "revit_mcp", "views.py"))
        colors = read(os.path.join(self.src, "revit_mcp", "colors.py"))
        self.assertNotIn("uidoc.ActiveView", views)
        self.assertEqual(views.count("active_graphical_view(uidoc.Document)"), 2)
        self.assertNotIn("doc.ActiveView", colors)

    def test_b_review_shows_text_and_escapes_what_hides(self):
        src = read(os.path.join(self.src, "revit_mcp", "security.py"))
        self.assertIn("preview = review_text(data)", src)
        start, end = src.index("HIDDEN = "), src.index("def authorize_request")
        ns = {"re": __import__("re"), "json": __import__("json")}
        exec(src[start:end], ns)
        text = ns["review_text"]({"code": "\u042f\u202e\u200b\ufeff\x07"})
        self.assertIn("\u042f", text)
        for hidden in "\u202e\u200b\ufeff\x07":
            self.assertNotIn(hidden, text)


if __name__ == "__main__":
    unittest.main()
