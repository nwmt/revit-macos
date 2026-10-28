"""tools/pyrevit48/revitmacos_serial.py: one Revit request at a time in pyRevit 4.8's Routes server, and the patch that
hands the server's Revit-context branch to it (tools/patches/pyrevit48/server.py.patch). The module runs inside Revit
on IronPython 2.7.7; here it runs on CPython 3 with a fake handler that shares one slot between requests, as pyRevit's
REQUEST_HNDLR does. Mutants (the module with one guard removed) must fail the test that guards against it."""
import os
import re
import shutil
import subprocess
import tempfile
import threading
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(ROOT, "tools", "pyrevit48", "revitmacos_serial.py")
PATCH = os.path.join(ROOT, "tools", "patches", "pyrevit48", "server.py.patch")
SERVER_URL = ("https://raw.githubusercontent.com/pyrevitlabs/pyRevit/v4.8.12.22247%2B0031/"
              "pyrevitlib/pyrevit/routes/server/server.py")
SERVER_SHA_LF = "3ac12d53d4b6935f75fbdd2466774076cc8bfa379340034958ac398ac4454f9a"
SERVER_SHA_CRLF = "6a1e0903edfcc69005813da00934ce7a7da06bd89abd4f3b294f3e1ae569f911"


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def load(text=None):
    src = text if text is not None else read(MODULE)
    mod = types.ModuleType("revitmacos_serial_under_test")
    exec(compile(src, MODULE, "exec"), mod.__dict__)
    return mod


class Req(object):
    def __init__(self, name, callback=None):
        self.name = name
        self.callback_url = callback


class Shared(object):
    """pyRevit's REQUEST_HNDLR: one object for every request; .response is whatever the last run produced."""
    def __init__(self):
        self.request = None
        self.response = None


class FakeHandler(object):
    """The HttpRequestHandler methods dispatch() calls. _call_host_event_sync runs the 'Revit' work: it answers for
    whatever request is in the shared slot when it runs, so overlapping requests get each other's answers."""
    def __init__(self, shared, gate=None, fail_call=False, fail_write=False):
        self.shared, self.gate, self.fail_call, self.fail_write = shared, gate, fail_call, fail_write
        self.written, self.prepared = [], 0

    def make_response(self, status, data):
        return (status, data)

    def _prepare_host_handler(self, request, route_handler):
        self.prepared += 1
        self.shared.request = request
        return self.shared, "event"

    def _call_host_event_sync(self, req, ev):
        if self.gate is not None:
            self.gate.wait(5)
        if self.fail_call:
            raise RuntimeError("handler failed")
        req.response = (200, req.request.name)

    def _write_response(self, response):
        if self.fail_write:
            raise IOError("client went away")
        self.written.append(response)


# The behaviours, as functions of the module under test (unittest methods call them with the real module; the mutant
# test calls them with a broken copy and expects an AssertionError).

def b_own_answers(tc, m):
    shared, gate = Shared(), threading.Event()
    h1, h2 = FakeHandler(shared, gate), FakeHandler(shared)
    t1 = threading.Thread(target=m.dispatch, args=(h1, Req("one"), None))
    t1.start()
    while shared.request is None:
        pass
    t2 = threading.Thread(target=m.dispatch, args=(h2, Req("two"), None))
    t2.start()
    t2.join(0.3)
    gate.set()
    t1.join(5)
    t2.join(5)
    tc.assertEqual(h1.written, [(200, "one")])
    tc.assertEqual(h2.written, [(200, "two")])


def b_second_waits(tc, m):
    shared, gate = Shared(), threading.Event()
    h1, h2 = FakeHandler(shared, gate), FakeHandler(shared)
    t1 = threading.Thread(target=m.dispatch, args=(h1, Req("one"), None))
    t1.start()
    while shared.request is None:
        pass
    t2 = threading.Thread(target=m.dispatch, args=(h2, Req("two"), None))
    t2.start()
    t2.join(0.3)
    try:
        tc.assertEqual(h2.prepared, 0, "the second request touched the shared handler while the first ran")
    finally:
        gate.set()
        t1.join(5)
        t2.join(5)


def b_timeout_503(tc, m):
    shared, gate = Shared(), threading.Event()
    h1 = FakeHandler(shared, gate)
    t1 = threading.Thread(target=m.dispatch, args=(h1, Req("one"), None))
    t1.start()
    while shared.request is None:
        pass
    now = [1000.0]

    def clock():
        return now[0]

    def sleep(s):
        now[0] += 30

    h2 = FakeHandler(shared)
    m.dispatch(h2, Req("two"), None, timeout=60, clock=clock, sleep=sleep)
    gate.set()
    t1.join(5)
    tc.assertEqual(h2.prepared, 0)
    tc.assertEqual(h2.written, [(503, {"error": "Revit is busy with another request"})])


def b_callback_400(tc, m):
    shared, gate = Shared(), threading.Event()
    h1 = FakeHandler(shared, gate)
    t1 = threading.Thread(target=m.dispatch, args=(h1, Req("one"), None))
    t1.start()
    while shared.request is None:
        pass
    h2 = FakeHandler(shared)
    m.dispatch(h2, Req("cb", callback="http://127.0.0.1:1/x"), None, timeout=60)   # the lock is held: must not wait
    gate.set()
    t1.join(5)
    tc.assertEqual(h2.prepared, 0)
    tc.assertEqual(h2.written, [(400, {"error": "Callbacks are not supported."})])


def b_release_after_call_error(tc, m):
    shared = Shared()
    h = FakeHandler(shared, fail_call=True)
    tc.assertRaises(RuntimeError, m.dispatch, h, Req("one"), None)
    h2 = FakeHandler(shared)
    m.dispatch(h2, Req("two"), None, timeout=1)
    tc.assertEqual(h2.written, [(200, "two")])


def b_release_after_write_error(tc, m):
    shared = Shared()
    h = FakeHandler(shared, fail_write=True)
    tc.assertRaises(IOError, m.dispatch, h, Req("one"), None)
    h2 = FakeHandler(shared)
    m.dispatch(h2, Req("two"), None, timeout=1)
    tc.assertEqual(h2.written, [(200, "two")])


def b_held_until_written(tc, m):
    """The lock is released only after _write_response: a request that comes in while the first is writing waits."""
    shared = Shared()
    seen = []

    class Slow(FakeHandler):
        def _write_response(self, response):
            seen.append(m._LOCK.locked())
            FakeHandler._write_response(self, response)

    m.dispatch(Slow(shared), Req("one"), None)
    tc.assertEqual(seen, [True])


class Dispatch(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_two_requests_get_their_own_answers(self):
        b_own_answers(self, self.m)

    def test_second_waits_for_first(self):
        b_second_waits(self, self.m)

    def test_lock_timeout_is_503_and_prepare_not_called(self):
        b_timeout_503(self, self.m)

    def test_callback_is_400_without_lock_or_prepare(self):
        b_callback_400(self, self.m)

    def test_exception_in_call_releases_lock(self):
        b_release_after_call_error(self, self.m)

    def test_exception_in_write_releases_lock(self):
        b_release_after_write_error(self, self.m)

    def test_lock_held_until_written(self):
        b_held_until_written(self, self.m)

    def test_module_is_ironpython2_safe(self):
        src = read(MODULE)
        for bad in ("f\"", "f'", "nonlocal", "async ", ":=", "print(", ".acquire(timeout", "import pyrevit",
                    "from pyrevit"):
            self.assertNotIn(bad, src)

    def test_mutants_fail(self):
        src = read(MODULE)
        mutants = {
            "ignore the callback check": (r"if getattr\(request, \"callback_url\", None\):", "if False:",
                                          b_callback_400),
            "go on without the lock": (r"while not _LOCK\.acquire\(False\):",
                                       "while not (_LOCK.acquire(False) or True):", b_second_waits),
            "release before writing": (r"(\n(\s+)handler\._write_response\(req_hndlr\.response\))",
                                       r"\n\2_LOCK.release()\1", b_held_until_written),
            "no finally": (r"finally:\n(\s+)_LOCK\.release\(\)", r"_LOCK.release()\n\1pass", b_release_after_call_error),
        }
        hook = threading.excepthook
        threading.excepthook = lambda args: None   # a mutant's threads fail on purpose; keep the output clean
        self.addCleanup(setattr, threading, "excepthook", hook)
        for name, (pat, rep, behaviour) in mutants.items():
            text, n = re.subn(pat, rep, src, count=1)
            self.assertEqual(n, 1, "mutant %r found nothing to change" % name)
            try:
                m = load(text)
                behaviour(self, m)
            except (AssertionError, RuntimeError, IOError, SyntaxError, NameError):
                continue
            self.fail("mutant %r passed its test" % name)


def fixture_server_crlf():
    """The pristine pyRevit 4.8.12 server.py with CRLF, as installed; None when it cannot be fetched (no network)."""
    r = subprocess.run(["bash", os.path.join(ROOT, "tests", "fixtures.sh"), SERVER_URL, SERVER_SHA_LF, "pyrevit48-server.py"],
                       capture_output=True, text=True)
    if r.returncode == 77:
        return None
    if r.returncode != 0:
        raise AssertionError("fixture: " + r.stdout + r.stderr)
    data = read(r.stdout.strip(), "rb").replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    import hashlib
    if hashlib.sha256(data).hexdigest() != SERVER_SHA_CRLF:
        raise AssertionError("the CRLF copy is not the installed file")
    return data


def method_text(src, name):
    m = re.search(r"\n    def %s\(.*?(?=\n    def |\nclass |\Z)" % name, src, re.S)
    return m.group(0) if m else ""


class Patch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        data = fixture_server_crlf()
        if data is None:
            raise unittest.SkipTest("SKIP: no network for the pyRevit 4.8.12 server.py fixture")
        cls.tmp = tempfile.mkdtemp()
        cls.orig = data.decode("ascii")
        p = os.path.join(cls.tmp, "server.py")
        with open(p, "wb") as f:
            f.write(data)
        for args in (["--dry-run"], []):
            r = subprocess.run(["patch", "-p0", "--binary", "-s"] + args + [p, PATCH], capture_output=True, text=True)
            if r.returncode != 0:
                raise AssertionError("patch: " + r.stdout + r.stderr)
        cls.raw = read(p, "rb")
        cls.src = cls.raw.decode("ascii").replace("\r\n", "\n")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(getattr(cls, "tmp", ""), ignore_errors=True)

    def test_patch_shape(self):
        self.assertNotIn(b"\n", self.raw.replace(b"\r\n", b""), "not CRLF throughout")
        route = method_text(self.src, "_handle_route")
        self.assertIn("return revitmacos_serial.dispatch(self, request, route_handler)", route)
        for call in ("_prepare_host_handler(", "_call_host_event(", "_call_host_event_sync("):
            self.assertNotIn("self." + call, route)
        self.assertIn("from pyrevit.routes.server import revitmacos_serial", self.src)
        others = [n for n in re.findall(r"\n    def (\w+)\(", self.src) if n not in ("_prepare_host_handler",)]
        for n in others:
            self.assertNotIn("self._prepare_host_handler(", method_text(self.src, n), n)
        self.assertIn("self._call_host_event(req_hndlr, event_hndlr)", method_text(self.src, "_call_host_event_sync"))

    def test_no_context_branch_unchanged(self):
        def tail(src):
            r = method_text(src, "_handle_route")
            return r[re.search(r"\n        else:\n", r).start():]
        self.assertEqual(tail(self.src), tail(self.orig.replace("\r\n", "\n")))

    def test_prepare_request_forwards_headers(self):
        text = method_text(self.src, "_prepare_request")

        class FakeRequest(object):
            def __init__(self, path=None, method=None, data=None, params=None):
                self.headers = {}

            def add_header(self, k, v):
                self.headers[k] = v

        class Headers(dict):
            def getheader(self, k):
                return self.get(k)

        ns = {"base": types.SimpleNamespace(Request=FakeRequest),
              "router": types.SimpleNamespace(extract_route_params=lambda p, path: []),
              "cgi": None, "json": None}
        exec(compile("class H(object):" + text, "server.py", "exec"), ns)
        h = ns["H"]()
        h.headers = Headers({"Authorization": "Bearer x"})
        req = h._prepare_request(types.SimpleNamespace(pattern="/x/"), "/x/", "GET")
        self.assertEqual(req.headers.get("Authorization"), "Bearer x")


if __name__ == "__main__":
    unittest.main()
