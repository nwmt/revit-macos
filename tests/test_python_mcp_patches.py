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
        with tarfile.open(r.stdout.strip()) as t:
            t.extractall(cls.tmp, filter="data")
        cls.src = os.path.join(cls.tmp, "mcp-server-for-revit-python-" + COMMIT)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def test_1_four_patches_apply_in_order(self):
        self.assertEqual([os.path.basename(p) for p in PATCHES],
                         ["01-code-execution-ipy2.patch", "02-views-unquote-ipy2.patch", "03-pairing-ioerror.patch",
                          "04-startup-error-file.patch"])
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


if __name__ == "__main__":
    unittest.main()
