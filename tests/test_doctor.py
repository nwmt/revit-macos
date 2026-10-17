# SPDX-License-Identifier: MIT
"""Unit tests for tools/doctor.py. Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Facts, bottles, CrossOver and the Mac's commands are made here: no Autodesk or Microsoft file, no real bottle. Only
test_cli runs doctor.py on this Mac, and checks nothing that depends on it."""
import fcntl, glob, hashlib, importlib.util, json, os, re, struct, subprocess, sys, tempfile, threading, time, unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TOOLS = os.path.join(REPO, "tools")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dr = load("doctor")
YEAR = 2025
STEPS = ["vc", "fonts", "dotnet", "licensing", "svcshim", "idmgr", "rvt", "pkgs", "asc", "revitini", "register",
         "ncryptshim", "webview2", "d3d9dxvk", "richedit", "tlbpin", "warpshim", "gdoff", "rvtfix", "wv2fix", "dynamo"]
PROFILE = {"YEAR": YEAR, "DOTNET": "net8", "SIGNIN": "idmgr", "STEPS": STEPS, "ENSCAPE": "",
           "RICHEDIT": ["msftedit", "riched20", "usp10", "msls31"], "ADDIN_STEPS": ["revitlookup"]}
BUILD = "26.3.0.39832"


def pe(ver, marker=b"", pad=3000):
    """A file that starts like a PE: a marker at 0x40 (or none) and a VS_FIXEDFILEINFO of version ver."""
    a, b, c, d = (int(x) for x in ver.split("."))
    fixed = b"\xbd\x04\xef\xfe" + struct.pack("<IIII", 0x00010000, (a << 16) | b, (c << 16) | d, 0)
    head = b"MZ" + bytes(62) + (marker or bytes(16))
    return head + bytes(pad) + fixed + bytes(64)


def builtin(tag):
    return b"MZ" + bytes(62) + b"Wine builtin DLL" + bytes(64) + tag.encode()


def marked(data, new):
    i = data.find(b"Wine builtin DLL")
    return data[:i] + new + data[i + 16:]


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Runner:
    """The Mac's commands, answered from a table; records every call. Anything not in the table cannot run."""

    def __init__(self, sb):
        self.sb, self.calls, self.ps, self.lsof = sb, [], "", ""
        self.table = {("sysctl", "-n", "hw.optional.arm64"): (0, "1\n"),
                      ("sysctl", "-n", "sysctl.proc_translated"): (0, "0\n"),
                      ("/usr/bin/arch",): (0, ""), ("sw_vers",): (0, "26.1\n"), ("osascript",): (0, "200\n")}

    def __call__(self, cmd, timeout=20):
        self.calls.append(list(cmd))
        if cmd[0] == "ps":
            return (0, self.ps) if self.ps is not None else (1, "")
        if cmd[0] == "lsof":
            return (0, self.lsof) if self.lsof is not None else (None, "")
        if cmd[0] == "osadecompile":
            return self.sb.scripts.get(cmd[1], (1, ""))
        for k, v in self.table.items():
            if tuple(cmd[:len(k)]) == k:
                return v
        return None, ""


class Sandbox(unittest.TestCase):
    """A fake CrossOver, a fake HOME with a bottle that a full install of PROFILE would leave, the shims it took."""
    year, profile, name = YEAR, PROFILE, "rvt2025-a"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self.tmp.name)   # lsof prints real paths
        j = os.path.join
        self.root, self.data, self.home = j(self.d, "repo"), j(self.d, "data"), j(self.d, "home")
        self.cx = j(self.d, "CrossOver.app", "Contents", "SharedSupport", "CrossOver")
        self.bottles = j(self.home, "Library", "Application Support", "CrossOver", "Bottles")
        self.b = j(self.bottles, self.name)
        self.scripts, self.runner = {}, Runner(self)
        for x in ("cxbottle", "wineserver", "wine"):   # if doctor ever ran one, it would leave a file
            self.write(j(self.cx, "bin", x), "#!/bin/sh\ntouch '%s/ran-%s'\n" % (self.d, x), mode=0o755)
        self.write(j(self.d, "CrossOver.app", "Contents", "Info.plist"),
                   '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString'
                   '</key><string>26.3</string><key>CFBundleVersion</key><string>%s</string></dict></plist>\n' % BUILD)
        self.cx_d3d9, self.cx_version = builtin("dxvk d3d9"), builtin("wine version")
        self.write(j(self.cx, dr.SOURCES["d3d9"][0]), self.cx_d3d9)
        self.write(j(self.cx, dr.SOURCES["version"][0]), self.cx_version)
        for s in ("d3dwp", "ncryptshim", "rvtfix", "svcshim", "tlbpin", "wbemshim", "wv2fix", "vkshim", "pdfprinter"):
            ext = ".exe" if s in ("svcshim", "pdfprinter") else ".dll"
            self.write(j(self.root, "build", s, s + ext), "fake " + s)
        self.write(j(self.root, "build", ".prebuilt"), "0.6.0\n")
        os.makedirs(j(self.home, "Documents"))
        self.make_bottle()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, path, data, mode=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        if mode:
            os.chmod(path, mode)
        return path

    def shim(self, s):
        with open(glob.glob(os.path.join(self.root, "build", s, "*.*"))[0], "rb") as f:
            return f.read()

    def make_bottle(self):
        j, b, y = os.path.join, self.b, self.year
        self.write(j(b, "cxbottle.conf"), '[Bottle]\n"Description" = "Revit %d"\n"Template" = "win10_64"\n'
                   '[EnvironmentVariables]\n"A" = "b"\n' % y)
        self.write(j(b, "system.reg"), "WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n"
                   "#arch=win64\n\n")
        self.write(j(b, "user.reg"), "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21\n\n")
        ini = "[Language]\r\nSelect=ENU\r\n[DirectoriesENU]\r\nDataLibraryLocations=x\r\n"
        self.write(j(b, "drive_c/users/crossover/AppData/Roaming/Autodesk/Revit/Autodesk Revit %d/Revit.ini" % y),
                   b"\xff\xfe" + ini.encode("utf-16-le"))
        os.makedirs(os.path.dirname(j(b, dr.DOCUMENTS)), exist_ok=True)
        os.symlink(j(self.home, "Documents"), j(b, dr.DOCUMENTS))
        self.write(j(b, dr.rd(y), "Revit.exe"), pe("25.5.0.57"))
        for step, sp in dr.specs(self.profile, y, self.profile["STEPS"]):
            if sp[0] == "shim":
                self.write(j(b, sp[3]), self.shim(sp[1]))
            elif sp[0] == "pemark":
                src = self.cx_d3d9 if sp[1] == "d3d9" else self.cx_version
                self.write(j(b, sp[3]), marked(src, dr.SOURCES[sp[1]][1]))
            elif sp[0] == "present":
                self.write(j(b, sp[2]), "ms " + os.path.basename(sp[2]))
        self.write(j(b, dr.WV2, "141.0.3537.71", "msedgewebview2.exe"), "x")
        os.makedirs(j(b, dr.DESKTOP, "8.0.1"))
        self.record(result="ok")
        for title in ("Revit %d" % y, "Autodesk Sign-In"):
            self.app(title)

    def app(self, title, bottle=None, wine=None):
        a = os.path.join(self.home, "Applications", "%s (%s).app" % (title, self.name))
        os.makedirs(os.path.join(a, "Contents", "Resources", "Scripts"), exist_ok=True)
        script = os.path.join(a, "Contents", "Resources", "Scripts", "main.scpt")
        line = "do shell script \"(cd ~ && '%s' --bottle '%s' 'C:\\\\x.exe' ) >/dev/null 2>&1 &\"\n"
        self.scripts[script] = (0, line % (wine or os.path.join(self.cx, "bin", "wine"), bottle or self.name))
        return a

    def record(self, kind="install", result="ok", failed=(), done=None, requested=None, **kw):
        req = list(requested if requested is not None else self.profile["STEPS"])
        rec = {"run_id": "r", "time": "2026-10-16T10:00:00Z", "kind": kind, "year": self.year, "requested": req,
               "done": list(done if done is not None else [s for s in req if s not in failed]), "skipped": [],
               "failed": list(failed), "result": result, "engine": "git:aaaaaaa", "crossover": BUILD,
               "compatdb_sha256": None, "shims": "0.6.0", "revit_build_expected": "25.5.0.57"}
        rec.update(kw)
        p = os.path.join(self.b, "revit-macos", "runs.ndjson")
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def records_clear(self):
        os.remove(os.path.join(self.b, "revit-macos", "runs.ndjson"))

    def ctx(self, year="default", bottle=None, profile=None, addins=None, engine="git:aaaaaaa", shims="0.6.0"):
        y = self.year if year == "default" else year
        return dr.Ctx(self.root, self.data, self.cx, self.bottles, os.path.join(self.root, "build"),
                      os.path.join(self.home, "lock"), BUILD, engine, shims, y, bottle or (self.name if y else None),
                      profile if profile is not None else (self.profile if y else None), addins, self.home, self.runner,
                      which=lambda t: True, hosts=lambda: True)

    def checks(self, **kw):
        self.facts = dr.collect(self.ctx(**kw))
        return dr.run_checks(self.facts)

    def by_id(self, checks):
        return {c.id: c for c in checks}

    def problems(self, checks, group=None):
        return sorted((c.id, c.status) for c in checks if c.status in ("fail", "warn") and group in (None, c.group))

    def snapshot(self):
        out = {}
        for root, dirs, files in os.walk(self.d):
            for n in dirs + files:
                p = os.path.join(root, n)
                st = os.lstat(p)
                out[p] = (st.st_ino, st.st_mtime_ns, st.st_size, st.st_mode)
        return out


class Bottle(Sandbox):
    def test_a_healthy_bottle_has_no_problems(self):
        cs = self.checks()
        self.assertEqual(self.problems(cs), [])
        ids = self.by_id(cs)
        for i in ("bottle.exists", "bottle.year", "bottle.registry", "bottle.revit", "bottle.documents",
                  "bottle.app.revit", "bottle.app.signin", "bottle.activity", "install.last", "install.steps",
                  "install.build", "crossover.since-install", "fixes.d3d9dxvk.system32.d3d9.dll",
                  "fixes.d3d9dxvk.revit.d3d9.dll", "fixes.warpshim.system32.version_orig.dll", "fixes.webview2",
                  "fixes.dotnet", "addins.none"):
            self.assertEqual(ids[i].status, "ok", i)
        self.assertNotIn("fixes.netfx", ids)   # a .NET year
        self.assertEqual(dr.render(cs)[-1], "  ✓ no problems found (%d checks)" % len(cs))

    def test_nothing_is_written_and_no_crossover_program_runs(self):
        self.records_clear()
        os.remove(os.path.join(self.b, "cxbottle.conf"))
        self.write(os.path.join(self.b, "cxbottle.conf"), '[Bottle]\n"Description" = "Revit 2025"\n')   # no env section
        before = self.snapshot()
        cs = self.checks()
        dr.render(cs, True)
        json.dumps([c.json() for c in cs])
        self.assertEqual(before, self.snapshot())
        self.assertEqual(glob.glob(os.path.join(self.d, "ran-*")), [])
        self.assertFalse([c for c in self.runner.calls if os.path.basename(c[0]) in ("wine", "wineserver", "cxbottle")])

    def test_each_file_check_fails_alone(self):
        rv = os.path.join(self.b, dr.rd(self.year))
        os.remove(os.path.join(rv, "d3dwp.dll"))
        self.assertEqual(self.problems(self.checks()), [("fixes.warpshim.revit.d3dwp.dll", "fail")])
        self.assertEqual(dr.summary(self.checks())["fail"], 1)

    def test_a_changed_fix_warns_with_what_it_fixes(self):
        self.write(os.path.join(self.b, dr.rd(self.year), "rvtfix.dll"), "older rvtfix")
        cs = self.checks()
        self.assertEqual(self.problems(cs), [("fixes.rvtfix.revit.rvtfix.dll", "warn")])
        c = self.by_id(cs)["fixes.rvtfix.revit.rvtfix.dll"]
        self.assertIn("the start screen stays blank", c.title)
        self.assertTrue(c.fix.endswith("it shows what it resets and asks first"))

    def test_copies_made_from_another_crossover(self):
        self.write(os.path.join(self.cx, dr.SOURCES["d3d9"][0]), builtin("dxvk d3d9, a newer build"))
        cs = self.checks()
        self.assertEqual(self.problems(cs), [("fixes.d3d9dxvk.revit.d3d9.dll", "warn"),
                                             ("fixes.d3d9dxvk.system32.d3d9.dll", "warn")])
        self.assertIn("made from another CrossOver", self.by_id(cs)["fixes.d3d9dxvk.system32.d3d9.dll"].title)

    def test_wine_own_dll_is_not_the_fix(self):
        self.write(os.path.join(self.b, dr.S32, "d3d9.dll"), builtin("wine stub"))
        self.write(os.path.join(self.b, dr.S32, "riched20.dll"), builtin("wine stub"))
        self.assertEqual(self.problems(self.checks()), [("fixes.d3d9dxvk.system32.d3d9.dll", "fail"),
                                                        ("fixes.richedit.system32.riched20.dll", "fail")])

    def test_a_file_two_steps_name_gets_the_stronger_check(self):
        ids = self.by_id(self.checks())   # richedit puts msls31.dll in place first, tlbpin replaces it with the shim
        self.assertIn("fixes.tlbpin.system32.msls31.dll", ids)
        self.assertNotIn("fixes.richedit.system32.msls31.dll", ids)
        self.write(os.path.join(self.b, dr.S32, "msls31.dll"), "ms msls31.dll")   # richedit ran, tlbpin did not
        self.assertEqual(self.problems(self.checks()), [("fixes.tlbpin.system32.msls31.dll", "warn")])
        self.write(os.path.join(self.b, dr.S32, "msls31.dll"), builtin("wine stub"))
        self.assertEqual(self.problems(self.checks()), [("fixes.tlbpin.system32.msls31.dll", "fail")])

    def test_files_that_must_not_be_there(self):
        rv = os.path.join(self.b, dr.rd(self.year))
        self.write(os.path.join(rv, "msftedit.dll"), "x")
        self.write(os.path.join(rv, "OGSDeviceDX11.dll.orig"), "x")
        self.write(os.path.join(self.b, dr.WV2, "141.0.3537.71", "version.dll"), "x")
        self.assertEqual(self.problems(self.checks()), [("fixes.richedit.revit.msftedit.dll", "warn"),
                                                        ("fixes.rvtfix.revit.OGSDeviceDX11.dll.orig", "warn"),
                                                        ("fixes.wv2fix.webview2.old-version.dll", "warn")])

    def test_shims_that_cannot_be_compared(self):
        os.remove(os.path.join(self.root, "build", "d3dwp", "d3dwp.dll"))
        cs = self.checks()
        self.assertEqual(self.problems(cs), [])
        c = self.by_id(cs)["fixes.warpshim.revit.d3dwp.dll"]
        self.assertEqual((c.status, c.show), ("info", False))

    def test_shim_sources_newer_than_the_build(self):
        os.remove(os.path.join(self.root, "build", ".prebuilt"))   # a clone that builds from source
        src = self.write(os.path.join(self.root, "tools", "shims", "rvtfix", "rvtfix.c"), "/* new */")
        os.utime(os.path.join(self.root, "build", "rvtfix", "rvtfix.dll"), (1000, 1000))
        self.write(os.path.join(self.b, dr.rd(self.year), "rvtfix.dll"), "older rvtfix")
        cs = self.by_id(self.checks())
        self.assertEqual(cs["fixes.rvtfix.revit.rvtfix.dll"].status, "info")
        os.utime(src, (500, 500))
        self.assertEqual(self.by_id(self.checks())["fixes.rvtfix.revit.rvtfix.dll"].status, "warn")

    def test_runtimes(self):
        os.rename(os.path.join(self.b, dr.WV2, "141.0.3537.71"), os.path.join(self.b, dr.WV2, "103.0.1264.37"))
        os.rmdir(os.path.join(self.b, dr.DESKTOP, "8.0.1"))
        os.makedirs(os.path.join(self.b, dr.DESKTOP, "10.0.0"))
        cs = self.by_id(self.checks())
        self.assertEqual((cs["fixes.webview2"].status, cs["fixes.dotnet"].status), ("fail", "fail"))
        self.assertIn("too old (103.0.1264.37)", cs["fixes.webview2"].title)

    def test_activity(self):
        real = self.b
        self.runner.ps = ("  101 /x/wineserver wineserver\n  102 /bin/zsh -zsh\n"
                          "  103 /x/wine-preloader C:\\a\\Revit.exe\n")
        for lsof, want in (("p101\nfcwd\nn%s\n" % real, "active"), ("p103\nn%s/drive_c/x.dll\n" % real, "active"),
                           ("p101\nn%s2/drive_c/x\n" % real, "stopped"), ("", "stopped"), (None, "unknown")):
            self.runner.lsof = lsof
            self.assertEqual(dr.activity(self.b, self.runner), want, lsof)
        self.assertIn("101,103", self.runner.calls[-1][-1])
        self.runner.ps = "  102 /bin/zsh -zsh\n"
        n = len(self.runner.calls)
        self.assertEqual(dr.activity(self.b, self.runner), "stopped")
        self.assertEqual([c[0] for c in self.runner.calls[n:]], ["ps"])   # no lsof without a Wine process
        self.runner.ps = None
        self.assertEqual(dr.activity(self.b, self.runner), "unknown")

    def test_records(self):
        self.records_clear()
        self.record(result="partial", failed=["tlbpin"])
        cs = self.by_id(self.checks())
        self.assertEqual(cs["install.last"].status, "warn")
        self.assertIn("views with text are created", cs["install.last"].title)
        self.record(kind="steps", result="ok", requested=["tlbpin"])
        self.assertEqual(self.by_id(self.checks())["install.last"].status, "ok")

    def test_a_step_the_bottle_never_ran(self):
        self.records_clear()
        self.record(requested=[s for s in STEPS if s != "wv2fix"])
        cs = self.checks()
        self.assertEqual(self.problems(cs), [("install.steps", "warn")])
        self.assertIn("the built-in browser crashes", self.by_id(cs)["install.steps"].title)
        self.assertFalse([c.id for c in cs if c.id.startswith("fixes.wv2fix.")])   # left to install.steps
        self.assertIn("fixes.warpshim.system32.version.dll", self.by_id(cs))   # warpshim still has its own

    def test_install_log_of_an_old_bottle(self):
        self.records_clear()
        d = os.path.join(self.data, "logs", self.name, "20261001-100000-install")
        self.write(os.path.join(d, "summary.txt"), "".join("   %-10s exit=0     x (1 s)\n" % s for s in STEPS) +
                   "   shims      exit=0     scripts/get-shims.sh (1 s)\n")
        self.write(os.path.join(d, "failed.txt"), "dynamo\n")
        cs = self.by_id(self.checks())
        self.assertEqual(cs["install.last"].status, "warn")
        self.assertIn("(2026-10-01)", cs["install.last"].title)
        self.assertEqual(cs["install.steps"].status, "ok")

    def test_build(self):
        self.assertEqual(self.by_id(self.checks())["install.build"].status, "ok")
        self.write(os.path.join(self.b, dr.rd(self.year), "Revit.exe"), pe("25.5.0.58"))
        self.assertEqual(self.by_id(self.checks())["install.build"].status, "warn")
        old, dr.VERIFIED_BUILD_YEARS = dr.VERIFIED_BUILD_YEARS, (self.year,)
        try:
            self.assertEqual(self.by_id(self.checks())["install.build"].status, "fail")
        finally:
            dr.VERIFIED_BUILD_YEARS = old
        self.records_clear()
        self.record(revit_build_expected=None)
        self.write(os.path.join(self.data, "installers", "extracted", "revit%d" % self.year, ".source"),
                   json.dumps({"files": [], "revit_build_expected": "25.5.0.58"}))
        c = self.by_id(self.checks())["install.build"]
        self.assertEqual((c.status, c.title), ("ok", "Revit.exe is build 25.5.0.58, as the installer gives"))

    def test_older_project_version_and_crossover(self):
        cs = self.checks(engine="git:bbbbbbb+dirty")
        c = self.by_id(cs)["install.engine"]
        self.assertEqual((c.status, c.show), ("info", True))
        self.assertEqual(c.title, "installed by an older version of this project; new fixes reach it after a rebuild")
        self.assertNotIn("install.engine", self.by_id(self.checks(engine="unknown")))
        self.assertNotIn("install.engine", self.by_id(self.checks(engine="git:aaaaaaa+dirty")))
        self.records_clear()
        self.record(crossover="26.2.0.1")
        c = self.by_id(self.checks())["crossover.since-install"]
        self.assertEqual(c.status, "warn")
        self.assertIn("26.2.0.1 then, %s now" % BUILD, c.title)
        self.assertTrue(c.fix.endswith("it shows what it resets and asks first"))

    def test_documents_and_apps(self):
        doc = os.path.join(self.b, dr.DOCUMENTS)
        self.assertEqual(self.by_id(self.checks())["bottle.documents"].title,
                         "Documents in the bottle is your Mac folder ~/Documents")
        os.remove(doc)
        os.symlink(os.path.join(self.d, "gone"), doc)
        self.assertEqual(self.by_id(self.checks())["bottle.documents"].status, "warn")
        os.remove(doc)
        os.makedirs(doc)
        self.assertEqual(self.by_id(self.checks())["bottle.documents"].status, "info")
        self.app("Revit %d" % self.year, bottle="rvt2025-b")
        self.assertIn("starts another bottle (rvt2025-b)", self.by_id(self.checks())["bottle.app.revit"].title)
        self.app("Revit %d" % self.year, wine=os.path.join(self.d, "old", "bin", "wine"))
        self.assertEqual(self.by_id(self.checks())["bottle.app.revit"].status, "warn")
        os.rename(self.app("Autodesk Sign-In"), os.path.join(self.d, "moved.app"))
        c = self.by_id(self.checks())["bottle.app.signin"]
        self.assertEqual((c.status, c.doc), ("warn", dr.DOC["signin"]))
        self.assertNotIn("bottle.app.signin", self.by_id(self.checks(profile=dict(PROFILE, SIGNIN="adsso"))))

    def test_bottle_that_cannot_be_checked(self):
        cs = self.checks(bottle="rvt2025-x")
        self.assertEqual(self.problems(cs, "bottle"), [("bottle.exists", "fail")])
        self.assertFalse([c for c in cs if c.group in ("install", "fixes", "addins")])
        os.symlink(self.b, os.path.join(self.bottles, "rvt2025-l"))
        self.assertIn("is a link", self.by_id(self.checks(bottle="rvt2025-l"))["bottle.exists"].title)
        self.assertEqual(self.problems(self.checks(year=2024, profile=dict(PROFILE, YEAR=2024))),
                         [("bottle.year", "fail")])
        self.write(os.path.join(self.b, dr.CLONE_MARKER), "state=ready\n")
        self.assertEqual(self.problems(self.checks()), [("bottle.clone", "fail")])

    def test_without_revit_exe_no_fix_is_checked(self):
        os.remove(os.path.join(self.b, dr.rd(self.year), "Revit.exe"))
        cs = self.checks()
        self.assertIn(("bottle.revit", "fail"), self.problems(cs))
        self.assertFalse([c for c in cs if c.group in ("fixes", "addins")])

    def test_addins(self):
        cs = self.by_id(self.checks(addins=[{"id": "pdfprinter", "name": "PDF printer"}]))
        self.assertEqual(cs["addins.pdfprinter"].title, "PDF printer is installed")
        self.facts["host"]["gs"] = False
        self.assertEqual(self.by_id(dr.run_checks(self.facts))["addins.pdfprinter.gs"].status, "warn")


CRASH = "wine: Unhandled page fault on read access to 0 at address 1 (thread 0040), starting debugger..."
HEALTHY = ["1.0:0030:0040:warn:seh:dispatch_exception code=c0000005 flags=0 addr=0000000140001000",
           "1.1:0030:0040:err:ole:ensure_mta Failed, hr 0x800401f0", "1.2:0030:0040:fixme:win:shm_surface_set_clip"]
LOADED = ('1.0:0030:0031:trace:loaddll:build_module Loaded L"C:\\\\Program Files\\\\Autodesk\\\\Revit 2025\\\\'
          'Revit.exe" at 0000000140000000: native')
ECDSA = '1.3:0030:0040:warn:seh:dispatch_exception "[ncrypt-shim] VerifySignature(32 bytes) -> 0xc000a000\\n"'


class Logs(Sandbox):
    """The logs group: the newest logs of the bottle against tools/signatures.py."""
    RUN = "20261016-120000"   # the install the run record names; the record says when it began

    def setUp(self):
        super().setUp()
        self.records_clear()
        self.record(result="ok", run_id=self.RUN + "-4242")
        self.logs = os.path.join(self.data, "logs", self.name)
        self.journals = os.path.join(self.b, "drive_c/users/crossover/AppData/Local/Autodesk/Revit",
                                     "Autodesk Revit %d" % self.year, "Journals")

    def lines(self, path, lines):
        return self.write(path, "\n".join(lines) + "\n")

    def session(self, stamp, lines, stdout=None):
        d = os.path.join(self.logs, stamp + "-debug")
        self.lines(os.path.join(d, "wine.cxlog"), lines)
        self.lines(os.path.join(d, "stdout.log"), stdout or ["fine"])
        return d

    def run_logs(self, stamp, kind, files):
        d = os.path.join(self.logs, "%s-%s" % (stamp, kind))
        for name, lines in files.items():
            self.lines(os.path.join(d, name), lines)
        self.write(os.path.join(d, "summary.txt"), "   rvt        exit=0     RVT.msi (8 s)\n")
        return d

    def journal(self, n, lines, when):
        p = self.lines(os.path.join(self.journals, "journal.%04d.txt" % n), lines)
        os.utime(p, (when, when))
        return p

    def logs_of(self, cs):
        return {c.id: c for c in cs if c.group == "logs"}

    def test_healthy_logs_are_no_problem(self):
        self.session("20261017-120000", [LOADED] + HEALTHY * 20)
        self.run_logs(self.RUN, "install", {"rvt.log": ["AdskLicensingService has been upgraded successfully"],
                                            "rvt.msi.log": ["Action ended 1:00:00: INSTALL. Return value 1."],
                                            "AdskLicensing-install.log": [
                                                "LIC-INST-ERROR-1053. Starting Windows service during new "
                                                "installation failed: Calling system API failed, (error code 1053)"]})
        self.journal(1, ["' 0:< License mode: User", "' 0:< DBG_WARN: Unable to create D2D render target"],
                     time.mktime((2026, 10, 17, 13, 0, 0, 0, 0, -1)))
        cs = self.checks()
        self.assertEqual(self.problems(cs), [])
        lg = self.logs_of(cs)
        self.assertEqual(lg["logs.signatures"].status, "ok")
        self.assertEqual(lg["logs.read"].title, "6 log files read")
        self.assertEqual(re.sub(r" \(\d+ bytes\)", "", lg["logs.read"].detail),
                         "logs/%s/20261017-120000-debug: wine.cxlog 61 lines, stdout.log 1 line; "
                         "logs/%s/%s-install: AdskLicensing-install.log 1 line, rvt.log 1 line, rvt.msi.log 1 line; "
                         "Journals: journal.0001.txt 2 lines" % (self.name, self.name, self.RUN))
        self.assertFalse(lg["logs.read"].show)
        self.assertIn("  ✓ no known failure in the newest logs", dr.render(cs, True))

    def test_a_crash_is_a_warning_with_its_session_and_what_to_do(self):
        d = self.session("20261017-120000", [LOADED] + HEALTHY + [CRASH] + HEALTHY)
        cs = self.checks()
        c = self.logs_of(cs)["logs.wine-crash"]
        self.assertEqual(c.status, "warn")
        when = dr.day(dr.run_time(d))
        self.assertEqual(c.title, "a Windows program in the bottle crashed (Revit.exe): seen in the Revit session of " +
                         when)
        self.assertEqual(c.fix, "see docs/troubleshooting.md#report-a-problem")
        self.assertEqual(c.detail, "logs/%s/20261017-120000-debug/wine.cxlog: line 5" % self.name)
        out = dr.render(cs)
        i = out.index("  ! " + c.title)
        self.assertEqual(out[i + 1], "      fix: see docs/troubleshooting.md#report-a-problem")
        self.assertFalse([x for x in cs if x.group == "logs" and x.status == "fail"])

    def test_the_same_signature_in_two_logs_is_one_warning(self):
        self.session("20261017-120000", [CRASH], stdout=[CRASH, CRASH])
        c = self.logs_of(self.checks())["logs.wine-crash"]
        self.assertIn("(process unknown)", c.title)
        self.assertEqual(c.detail.count("line "), 2)
        self.assertIn("stdout.log: line 1, 2", c.detail)

    def test_logs_older_than_the_last_install_are_not_read(self):
        self.session("20261015-120000", [CRASH])
        self.run_logs("20261015-110000", "install", {"rvt.msi.log": ["Action ended 1:00:00: INSTALL. Return value 0."]})
        self.journal(3, ["' 0:< captureTryCrash 0xc0000005"], time.mktime((2026, 10, 15, 12, 0, 0, 0, 0, -1)))
        cs = self.checks()
        lg = self.logs_of(cs)
        self.assertEqual(self.problems(cs, "logs"), [])
        self.assertIn("logs.skipped", lg)
        self.assertEqual(lg["logs.skipped"].title.count("the "), 4)   # "older than the last install", three logs
        self.assertNotIn("logs.signatures", lg)

    def test_the_newest_run_and_its_failures(self):
        self.run_logs(self.RUN, "install", {"rvt.msi.log": ["Action ended 1:00:00: INSTALL. Return value 0."]})
        cs = self.by_id(self.checks())
        self.assertEqual(cs["logs.msi-failed"].status, "warn")
        self.assertIn("seen in the install of", cs["logs.msi-failed"].title)
        self.assertEqual(cs["logs.msi-failed"].fix, "./revit rebuild 2025: it shows what it resets and asks first")
        self.assertEqual(cs["logs.msi-failed"].doc, "docs/troubleshooting.md#start-over")
        self.run_logs("20261016-130000", "steps", {"rvt.log": [
            "the Autodesk licensing service does not answer, so RVT.msi would fail"]})
        cs = self.by_id(self.checks())
        self.assertNotIn("logs.msi-failed", cs)   # the install is no longer the newest run
        self.assertIn("seen in the steps run of", cs["logs.licensing-no-answer"].title)
        self.assertEqual(cs["logs.licensing-no-answer"].doc,
                         "docs/troubleshooting.md#install-stops-the-autodesk-licensing-service-does-not-answer")

    def test_utf16_msi_log_and_journal(self):
        d = self.run_logs(self.RUN, "install", {})
        self.write(os.path.join(d, "core.msi.log"),
                   b"\xff\xfe" + "Action ended 1:00:00: X. Return value 3.\r\n".encode("utf-16-le"))
        self.journal(7, ["' 0:< Assertion failed: line 52"], time.mktime((2026, 10, 18, 9, 0, 0, 0, 0, -1)))
        cs = self.by_id(self.checks())
        self.assertEqual(cs["logs.msi-failed"].detail,
                         "logs/%s/%s-install/core.msi.log: line 1" % (self.name, self.RUN))
        self.assertIn("seen in the Revit session of", cs["logs.journal-assertion"].title)
        self.assertEqual(cs["logs.journal-assertion"].detail, "Journals/journal.0007.txt: line 1")

    def test_ecdsa_counts_in_the_json_only(self):
        self.session("20261017-120000", HEALTHY + [ECDSA] * 3 + [ECDSA.replace("0xc000a000", "0x0")])
        cs = self.checks()
        c = self.logs_of(cs)["logs.ecdsa-verify"]
        self.assertEqual((c.status, c.show, json.loads(c.detail)), ("info", False, {"failed": 3, "passed": 1}))
        self.assertFalse([x for x in dr.render(cs) if "ECDSA" in x])
        self.assertEqual(self.problems(cs), [])

    def test_no_logs(self):
        lg = self.logs_of(self.checks())
        self.assertEqual(sorted(lg), ["logs.read"])
        self.assertEqual(lg["logs.read"].title, "no logs of this bottle to read")

    def test_a_log_that_grows_while_read(self):
        d = self.session("20261017-120000", [LOADED] + [CRASH] + HEALTHY * 100000)
        p, stop = os.path.join(d, "wine.cxlog"), threading.Event()

        def grow():   # Revit still runs: lines, then half a line, go on arriving at the end
            with open(p, "a") as f:
                while not stop.is_set():
                    f.write(HEALTHY[1] + "\n" + HEALTHY[2][:20])
                    f.flush()
        t = threading.Thread(target=grow)
        t.start()
        try:
            cs = self.by_id(self.checks())
        finally:
            stop.set()
            t.join()
        self.assertEqual(cs["logs.wine-crash"].status, "warn")
        self.assertEqual(cs["logs.wine-crash"].detail, "logs/%s/20261017-120000-debug/wine.cxlog: line 2" % self.name)

    def test_logs_are_read_and_not_written(self):
        self.session("20261017-120000", [CRASH])
        before = self.snapshot()
        self.checks()
        self.assertEqual(before, self.snapshot())

    def test_a_huge_cxlog_stays_fast(self):
        d = os.path.join(self.logs, "20261017-120000-debug")
        os.makedirs(d)
        p = os.path.join(d, "wine.cxlog")
        line = b"540731.357:04a8:02d8:trace:seh:dispatch_exception  rax=0000000000000000 rbx=00000000001ff6e0\n"
        block = (line * 9 + HEALTHY[0].encode() + b"\n") * ((1 << 20) // (10 * len(line)) + 1)
        with open(p, "wb") as f:   # over 1 GB: a sparse start, then about 320 MB of lines that end with a crash
            f.write(("\n".join([CRASH] + HEALTHY) + "\n").encode())
            f.seek((1 << 30) - (300 << 20))
            for _ in range(320):
                f.write(block)
            f.write(("1.9:0030:0040:warn:seh:dispatch_exception code=c0000005\n" + CRASH + "\n").encode())
        t = time.monotonic()
        cs = self.by_id(self.checks())
        took = time.monotonic() - t
        self.assertLess(took, 60, "doctor took %.1f s on a 1 GB wine.cxlog" % took)
        self.assertEqual(cs["logs.wine-crash"].status, "warn")
        m = re.match(r"^logs/.*-debug: wine\.cxlog \((\d+) bytes\) (\d+) lines from byte (\d+) on$",
                     cs["logs.read"].detail)
        size, lines, first = (int(x) for x in m.groups())
        self.assertGreater(size, 1 << 30)
        self.assertLessEqual(lines, dr.signatures.LINES_MAX)   # its end only
        self.assertGreaterEqual(first, size - dr.signatures.WINDOW)   # where its last lines begin
        # the start is not read, so the line numbers count from the first line read, and say so
        self.assertRegex(cs["logs.wine-crash"].detail, r"wine\.cxlog: line %d of its last %d lines$" % (lines, lines))


class NetFramework(Sandbox):
    year, name = 2024, "rvt2024-a"
    profile = dict(PROFILE, YEAR=2024, DOTNET="netfx48", STEPS=["netfx", "ncryptshim"])

    def reg(self, release):
        key = "[Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1729000000\n"
        body = "" if release is None else \
            key + '#time=1d0\n"Release"=dword:%08x\n"Version"="4.8.03761"\n\n' % release
        self.write(os.path.join(self.b, "system.reg"), "WINE REGISTRY Version 2\n\n[Software\\\\Other] 1\n"
                   '"Data"=hex:01,02,\\\n  03\n\n' + body)

    def netfx(self, **kw):
        return self.by_id(self.checks(**kw))["fixes.netfx"]

    def test_release(self):
        self.write(os.path.join(self.b, dr.NETFX_DIR, "clr.dll"), "x")
        self.reg(528040)
        self.assertEqual(self.netfx().status, "ok")
        self.reg(0x6040e)
        self.assertEqual(self.netfx().status, "fail")
        os.remove(os.path.join(self.b, dr.NETFX_DIR, "clr.dll"))
        self.assertEqual(self.netfx().status, "fail")

    def test_a_missing_key_while_the_bottle_runs_is_not_a_problem(self):
        self.write(os.path.join(self.b, dr.NETFX_DIR, "clr.dll"), "x")
        self.reg(None)
        self.assertEqual(self.netfx().status, "warn")
        self.runner.ps, self.runner.lsof = "  7 /x/wineserver\n", "p7\nn%s\n" % self.b
        c = self.netfx()
        self.assertEqual(c.status, "info")
        self.assertIn("not visible (bottle active)", c.title)
        self.assertEqual(self.problems(self.checks()), [])
        os.remove(os.path.join(self.b, "system.reg"))
        self.runner.ps = ""
        self.assertEqual(self.netfx().status, "ok")   # no registry at all: bottle.registry says so

    def test_reg_values(self):
        self.reg(0x80ea8)
        p = os.path.join(self.b, "system.reg")
        self.assertEqual(dr.reg_values(p, dr.NDP_KEY), {"release": ("dword", 0x80ea8), "version": ("sz", "4.8.03761")})
        self.assertEqual(dr.reg_values(p, "SOFTWARE\\OTHER"), {"data": ("hex", b"\x01\x02\x03")})
        self.assertEqual(dr.reg_values(p, "Software\\Missing"), {})
        self.assertIsNone(dr.reg_values(p + ".gone", dr.NDP_KEY))


class Revit2020(NetFramework):
    year, name = 2020, "rvt2020-a"
    profile = dict(PROFILE, YEAR=2020, DOTNET="netfx47", STEPS=["netfx"])

    def test_release_too_new_for_2020(self):
        self.write(os.path.join(self.b, dr.NETFX_DIR, "clr.dll"), "x")
        self.reg(0x80ea8)
        c = self.netfx()
        self.assertEqual((c.status, c.doc), ("warn", dr.DOC["netfx2020"]))

    test_release = None


class WithoutYear(Sandbox):
    def test_bottles_and_leftover_copies(self):
        os.makedirs(os.path.join(self.bottles, "exp", "drive_c"))   # not a Revit bottle
        os.symlink(self.b, os.path.join(self.bottles, "rvt2025-t"))
        c2 = os.path.join(self.bottles, "rvt2025-a.test")
        self.write(os.path.join(c2, dr.CLONE_MARKER), "run_id=x\nsource=rvt2025-a\nstate=ready\n")
        cs = self.checks(year=None)
        ids = self.by_id(cs)
        self.assertEqual(sorted(i for i in ids if i.startswith("bottles.")),
                         ["bottles.clone.rvt2025-a.test", "bottles.rvt2025-a"])
        self.assertEqual(ids["bottles.rvt2025-a"].title, "rvt2025-a: Revit 2025")
        c = ids["bottles.clone.rvt2025-a.test"]
        self.assertEqual(c.status, "warn")
        self.assertIn('rm -rf "$HOME/Library/Application Support/CrossOver/Bottles/rvt2025-a.test"', c.fix)
        self.assertNotIn(self.home, c.fix + c.title)
        self.assertFalse([x for x in cs if x.group in ("bottle", "install", "fixes")])
        shutil_rm(self.bottles)
        self.assertIn("bottles.none", self.by_id(self.checks(year=None)))


def shutil_rm(path):
    import shutil
    shutil.rmtree(path)


def facts(**over):
    """Synthetic facts of a good Mac and CrossOver, without a year."""
    f = {"year": None, "bottle": None, "sfx": "", "profile": {}, "addins": [], "engine": "unknown",
         "shims_release": "unknown", "home": "/h", "bottles_path": "/h/B", "bottles": [],
         "host": {"arm64": True, "translated": False, "rosetta": True, "macos": "26.1",
                  "tools": {"7zz": True, "winetricks": True, "cabextract": True, "python3": True}, "gs": True,
                  "space": [{"dev": 1, "labels": ["bottles", "installers/extracted"], "gb": 120,
                             "volume": "this Mac's disk"}],
                  "gone": [], "hosts": True, "lock": {"busy": False, "owner": ""}},
         "cx": {"found": True, "version": "26.3", "build": BUILD, "tested": BUILD,
                "markers": {"d3d9": True, "version": True},
                "pemark": {}, "parts": {"D3DMetal": "3.0 (1)", "MoltenVK": "1.2.10"}, "compatdb_sha256": "ab" * 32}}
    for k, v in over.items():
        if isinstance(v, dict):
            f[k] = dict(f[k], **v)
        else:
            f[k] = v
    return f


class Host(unittest.TestCase):
    def status(self, f, cid):
        return {c.id: c for c in dr.run_checks(f)}[cid]

    def test_good_mac(self):
        cs = dr.run_checks(facts())
        self.assertEqual([c for c in cs if c.status in ("fail", "warn")], [])
        out = "\n".join(dr.render(cs))
        self.assertNotIn("D3DMetal", out)
        self.assertNotIn("host.", out)
        self.assertIn("✓ no problems found (%d checks)" % len(cs), out)
        self.assertNotIn("✓ Rosetta 2 is installed", out)
        self.assertIn("  ✓ Rosetta 2 is installed", "\n".join(dr.render(cs, True)))
        self.assertNotIn("D3DMetal", "\n".join(dr.render(cs, True)))
        js = [c.json() for c in cs]
        self.assertTrue(any("D3DMetal 3.0" in c["title"] for c in js))
        for c in js:
            self.assertEqual(sorted(c), ["detail", "doc", "fix", "group", "id", "status", "title"])
            self.assertIn(c["status"], ("ok", "warn", "fail", "info"))
            self.assertEqual(c["group"], c["id"].split(".")[0])
        s = dr.summary(cs)
        self.assertEqual(s["checks"], s["ok"] + s["warn"] + s["fail"] + s["info"])

    def test_problems(self):
        c = self.status(facts(host={"rosetta": False}), "host.rosetta")
        self.assertEqual((c.status, c.fix, c.doc),
                         ("fail", "softwareupdate --install-rosetta --agree-to-license", dr.DOC["rosetta"]))
        self.assertEqual(self.status(facts(host={"translated": True}), "host.terminal").status, "fail")
        self.assertEqual(self.status(facts(host={"arm64": False}), "host.arm64").status, "fail")
        c = self.status(facts(host={"hosts": False}), "host.hosts")
        self.assertEqual(c.status, "warn")
        self.assertIn('"$(hostname)"', c.fix)
        c = self.status(facts(host={"tools": {"7zz": False}}), "host.tool.7zz")
        self.assertEqual((c.status, c.fix), ("warn", "brew install sevenzip"))
        self.assertEqual(self.status(facts(host={"macos": "15.4"}), "host.macos").status, "warn")
        low = [{"dev": 2, "labels": ["installers/extracted"], "gb": 4, "volume": "an external volume"}]
        c = self.status(facts(host={"space": low}), "host.space.installers-extracted")
        self.assertEqual((c.status, c.title), ("warn", "only 4 GB free on an external volume (installers/extracted)"))
        c = self.status(facts(host={"gone": ["installers/revit2025"]}), "host.space.installers-revit2025")
        self.assertEqual(c.status, "warn")
        c = self.status(facts(host={"lock": {"busy": True, "owner": "./revit install 2025 rvt2025-a"}}), "host.lock")
        self.assertEqual((c.status, c.show, c.title),
                         ("info", True, "another task is running: ./revit install 2025 rvt2025-a"))

    def test_crossover(self):
        cs = {c.id: c for c in dr.run_checks(facts(cx={"found": False}))}
        self.assertEqual(cs["crossover.found"].status, "fail")
        self.assertFalse([i for i in cs if i.startswith("crossover.") and i != "crossover.found"])
        self.assertEqual(self.status(facts(cx={"build": "26.4.0.1"}), "crossover.version").status, "warn")
        c = self.status(facts(cx={"markers": {"d3d9": False, "version": True}}), "crossover.files")
        self.assertEqual(c.status, "warn")

    def test_render(self):
        cs = dr.run_checks(facts(host={"rosetta": False, "hosts": False}))
        out = dr.render(cs)
        self.assertEqual(out[0], "  ✗ Rosetta 2 is not installed: the Revit app fails without a message")
        self.assertEqual(out[1], "      fix: softwareupdate --install-rosetta --agree-to-license")
        self.assertTrue(out[2].startswith("  ! this Mac's name is not in /etc/hosts"))
        self.assertTrue(out[3].startswith("      fix: "))
        self.assertEqual(out[-1], "  1 problem and 1 warning (%d checks)" % len(cs))


class Readers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.realpath(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_hosts(self):
        p = os.path.join(self.d, "hosts")
        with open(p, "w") as f:
            f.write("127.0.0.1\tlocalhost\n127.0.0.1\tstudio-x.local\n")
        self.assertTrue(dr.hosts_has_name("studio-x.local", p))
        self.assertFalse(dr.hosts_has_name("studio-y", p))
        self.assertFalse(dr.hosts_has_name("studio-x", p))
        self.assertIsNone(dr.hosts_has_name("a", p + ".gone"))

    def test_lock(self):
        lock = os.path.join(self.d, "lock")
        self.assertEqual(dr.lock_state(lock), {"busy": False, "owner": ""})
        with open(lock + ".owner", "w") as f:
            f.write("command=./revit install 2025 rvt2025-a\nrun_id=x\n")
        h = open(lock, "a")
        try:
            fcntl.flock(h, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(dr.lock_state(lock), {"busy": True, "owner": "./revit install 2025 rvt2025-a"})
        finally:
            h.close()
        self.assertFalse(dr.lock_state(lock)["busy"])

    def test_space(self):
        data, home = os.path.join(self.d, "data"), os.path.join(self.d, "home")
        os.makedirs(os.path.join(data, "installers"))
        os.makedirs(home)
        os.symlink(os.path.join(self.d, "no-volume"), os.path.join(data, "installers", "extracted"))
        os.symlink(os.path.join(self.d, "user-folder"), os.path.join(data, "installers", "revit2025"))
        ctx = dr.Ctx(self.d, data, self.d, os.path.join(home, "B"), year=2025, bottle="rvt2025-a", home=home,
                     runner=lambda cmd, timeout=20: (0, "77\n"), which=lambda t: True, hosts=lambda: True)
        vols, gone = dr.space(ctx)
        self.assertEqual(sorted(gone), ["installers/extracted", "installers/revit2025"])
        self.assertEqual([(v["labels"], v["gb"], v["volume"]) for v in vols],
                         [(["bottles", "installers/revit2025-dl"], 77, "this Mac's disk")])

    def test_show(self):
        ctx = dr.Ctx("/r", "/u/x/data", "/c", "/u/x/B", home="/u/x")
        self.assertEqual(dr.show("/u/x/data/installers/extracted", ctx), "installers/extracted")
        self.assertEqual(dr.show("/u/x/Documents", ctx), "~/Documents")
        self.assertEqual(dr.show("/Volumes/Studio/Revit", ctx), "an external volume")


class Contract(unittest.TestCase):
    def test_every_step_has_a_table_entry(self):
        steps = set()
        for f in glob.glob(os.path.join(REPO, "scripts", "steps", "*.sh")):
            with open(f, encoding="utf-8") as h:
                steps.update(re.findall(r"^step_([A-Za-z0-9_-]+)\(\)", h.read(), re.M))
        self.assertTrue(steps)
        self.assertEqual(sorted(steps - set(dr.FIXES)), [], "steps without an entry in doctor.FIXES")
        self.assertEqual(sorted(set(dr.FIXES) - steps), [], "entries for steps that do not exist")
        for s, fx in dr.FIXES.items():
            self.assertTrue(fx["symptom"], s)
            self.assertTrue(fx["checks"] or fx["why"], s)

    def test_doc_anchors_exist(self):
        with open(os.path.join(REPO, "docs", "troubleshooting.md"), encoding="utf-8") as f:
            heads = re.findall(r"^#+ (.+)$", f.read(), re.M)
        anchors = {re.sub(r"[^a-z0-9 -]", "", h.lower()).replace(" ", "-") for h in heads}
        for k, v in dr.DOC.items():
            self.assertIn(v.split("#", 1)[1], anchors, k)

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, HOME=d)
            args = [sys.executable, "-I", "-B", os.path.join(TOOLS, "doctor.py"), "--root", d, "--data", d,
                    "--cx", os.path.join(d, "cx"), "--bottles", os.path.join(d, "B")]
            r = subprocess.run(args + ["--json"], capture_output=True, text=True, env=env)
            out = json.loads(r.stdout)
            self.assertEqual(r.returncode, 1 if out["summary"]["fail"] else 0)
            self.assertIn("crossover.found", [c["id"] for c in out["checks"]])
            r = subprocess.run(args + ["--year", "2025"], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(os.listdir(d), [])   # wrote nothing


if __name__ == "__main__":
    unittest.main()
