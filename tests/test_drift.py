# SPDX-License-Identifier: MIT
"""Tests for tools/installer_drift.py (expected Revit build, installer check) and its use in install.sh's preflight.
Run: python3 -I -m unittest discover -s tests -p 'test_*.py'
Every manifest is generated here, with attributes in unusual orders and a namespace; a fake 7zz on PATH prints the
member files the tests put next to each archive. Nothing from Autodesk or Microsoft is needed."""
import json, os, shutil, stat, subprocess, sys, tempfile, unittest

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TOOLS = os.path.join(REPO, "tools")
NS = 'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="" xmlns="urn:example:manifest"'
# e <archive> <member>: prints <archive>.<member with / as _> if it is there; x: copies <archive>.tree/ into -o<dir>;
# an archive with <archive>.broken next to it prints garbage and fails. Every call goes to calls.log
FAKE_7ZZ = r"""#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/calls.log"
a=""; out=""
for x in "$@"; do case "$x" in -o*) out="${x#-o}" ;; *) [ -z "$a" ] && [ -f "$x" ] && a="$x" ;; esac; done
[ -n "$a" ] && [ -f "$a.broken" ] && { echo "<Bundle><Identity><BuildNumber>"; exit 2; }
case "$1" in
  e) m="${!#}"; f="$a.$(printf '%s' "$m" | tr '/' '_')"; [ -f "$f" ] && cat "$f" ;;
  x) [ -d "$a.tree" ] && mkdir -p "$out" && cp -R "$a.tree/." "$out/" ;;
esac
exit 0
"""


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def setup_xml(build, packages=(), targets=(), root="Bundle"):
    """An ODIS setup.xml: the build in Identity (the attribute first), the builds it applies to, its packages."""
    t = "".join(f"<Target><DisplayName>R</DisplayName><BuildNumber>{b}</BuildNumber></Target>" for b in targets)
    p = "".join(f'<Package upi2="{{0}}" path="{path}" external="false" name="{name}" installAs="core"/>' for name, path in packages)
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<{root} version="1.0" {NS}>\n'
            f'  <Identity><Publisher>P</Publisher><BuildNumber envvar="REVIT_BUILD_NUMBER">{build}</BuildNumber><Type>UPD</Type></Identity>\n'
            f"  <Configuration><AdditionalBundleInfo updateBundle=\"true\"><Targets>{t}</Targets></AdditionalBundleInfo></Configuration>\n"
            f"  <Packages>{p}</Packages>\n</{root}>\n")


def app_xml(packages):
    p = "".join(f'<Package path="{path}" installAs="core" name="{name}" upgradeCode="{{1}}"/>' for name, path in packages)
    return f'<?xml version="1.0" encoding="UTF-8"?>\n<Application {NS}><Identity><BuildNumber>1</BuildNumber></Identity><Packages>{p}</Packages></Application>\n'


def pkg_xml(kind="ADIX", build="1.0.0.0", deps=()):
    d = "".join(f'<Package path="{path}" name="{name}" external="true"/>' for name, path in deps)
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<Package version="1.0" {NS}><Identity><BuildNumber>{build}</BuildNumber></Identity>'
            f'<Configuration><InstallFile installParams="" type="{kind}" contents="File" file="x"/></Configuration>'
            f"<Dependencies>{d}</Dependencies></Package>\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = os.path.join(os.path.realpath(self.tmp.name), "sand box")   # a space in every path
        self.bin = self.p("bin")
        self.put("bin/7zz", FAKE_7ZZ); os.chmod(os.path.join(self.bin, "7zz"), 0o755)
        os.symlink(sys.executable, os.path.join(self.bin, "python3"))
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": self.p("home"), "LANG": "en_US.UTF-8",
                    "TMPDIR": self.p("tmp") + "/"}
        os.makedirs(self.p("tmp")); os.makedirs(self.p("home"))

    def tearDown(self):
        self.tmp.cleanup()

    def p(self, *a):
        return os.path.join(self.d, *a)

    def put(self, rel, text):
        f = self.p(rel); os.makedirs(os.path.dirname(f), exist_ok=True)
        write(f, text)
        return f

    def calls(self):
        try:
            return read(os.path.join(self.bin, "calls.log"))
        except OSError:
            return ""

    def source(self, entries, kind="archive", name="source.json"):
        """A source list as installer_source.py writes it: entries are (role, file under the sandbox, build, extract)."""
        files = [{"role": r, "path": self.p(f), "url": None, "size": None, "expected_sha256": None, "sha256": None,
                  "extract": x, "build": b} for r, f, b, x in entries]
        return self.put(name, json.dumps({"year": "2025", "kind": kind, "files": files}))

    def tool(self, *a):
        return subprocess.run([sys.executable, "-I", "-B", os.path.join(TOOLS, "installer_drift.py"), *a],
                              capture_output=True, text=True, env=self.env, cwd="/")

    def build(self, *a):
        r = self.tool("expected-build", *a)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def dist(self, rel, build="25.0.2.419", packages=(), licensing=None, applied=(), lic_dir="Licensing"):
        """An unpacked installer: setup.xml, manifest/app.RVT.xml, a pkg.*.xml per package (name, path, type, deps)."""
        self.put(f"{rel}/setup.xml", setup_xml(build, root="Bundle"))
        self.put(f"{rel}/manifest/app.RVT.xml", app_xml([(n, p) for n, p, _, _ in packages]))
        for _, path, kind, deps in packages:
            self.put(f"{rel}/{path}", pkg_xml(kind, deps=deps))
        if licensing:
            self.put(f"{rel}/x86/{lic_dir}/pkg.licensing.xml", pkg_xml("EXE", licensing))
        if applied:
            self.put(f"{rel}/applied-updates.txt", "".join(f"{n}\n" for n in applied))
        return self.p(rel)


class ExpectedBuild(Base):
    def test_the_highest_build_of_the_unpacked_base_and_the_updates(self):
        dist = self.dist("ex/revit2025")
        self.put("in/update/U2.exe", "x"); self.put("in/update/U2.exe.setup.xml", setup_xml("25.10.0.3"))
        sl = self.source([("update", "in/update/U1.exe", "25.5.0.57", False), ("update", "in/update/U2.exe", None, False)])
        self.assertEqual(self.build("2025", sl, dist), "25.10.0.3")   # by number: 10 > 5
        self.assertIn("-t7z", self.calls())   # an update's .exe is read as 7z: fast
        self.assertNotIn("U1.exe", self.calls())   # its build came from the list

    def test_the_build_of_the_update_itself_not_of_its_targets(self):
        self.put("in/update/U.exe", "x")
        self.put("in/update/U.exe.setup.xml", setup_xml("25.5.0.57", targets=["99.0.0.1", "25.0.2.419"]))
        self.assertEqual(self.build("2025", self.source([("update", "in/update/U.exe", None, False)])), "25.5.0.57")

    def test_an_update_of_unknown_build_makes_it_unknown(self):
        sl = self.source([("update", "in/update/gone.exe", None, False)])
        self.assertEqual(self.build("2025", sl, self.dist("ex/revit2025")), "unknown")
        self.put("in/update/U.exe", "x"); self.put("in/update/U.exe.setup.xml", "<Bundle><Identity/></Bundle>")
        self.assertEqual(self.build("2025", self.source([("update", "in/update/U.exe", "?", False)])), "unknown")

    def test_setup_ini_is_unknown(self):
        self.put("ex/revit2020/Revit_2020/Setup.ini", "[SETUP]\n")
        sl = self.source([("update", "in/update/U.exe", "20.1.0.1", False)])
        self.assertEqual(self.build("2020", sl, self.p("ex/revit2020/Revit_2020")), "unknown")

    def test_the_base_archive_only_without_updates(self):
        self.put("in/RVT_2026_B_002_002.7z", "x"); self.put("in/RVT_2026_B_002_002.7z.setup.xml", setup_xml("26.0.4.409"))
        base = ("base", "in/RVT_2026_B_002_002.7z", None, True)
        self.assertEqual(self.build("2026", self.source([base])), "26.0.4.409")
        os.remove(os.path.join(self.bin, "calls.log"))
        self.assertEqual(self.build("2026", self.source([base, ("update", "in/update/U.exe", "26.5.0.55", False)])), "26.5.0.55")
        self.assertEqual(self.calls(), "")   # 4-5 s saved: an update always has the later build

    def test_the_create_installer_names_the_base(self):
        self.put("in/CI.exe", "x")
        self.put("in/CI.exe.tree/RVT_2027_en-US/setup.xml", setup_xml("27.0.4.412"))
        self.put("in/CI.exe.tree/RVT_2027_en-US/manifest/app.RVT.xml", app_xml([]))
        ci, base = ("create-installer", "in/CI.exe", None, False), ("base", "dl/RVT_2027_B_002_002.7z", None, True)
        self.assertEqual(self.build("2027", self.source([ci, base], "create-installer")), "27.0.4.412")
        up = ("update", "dl/update/U.exe", "27.3.0.28", False)   # not downloaded yet: the list has its build
        self.assertEqual(self.build("2027", self.source([ci, base, up], "create-installer")), "27.3.0.28")

    def test_a_multi_part_download_is_not_read(self):
        self.put("in/R_2023_dlm_001_002.sfx.exe", "x")
        self.assertEqual(self.build("2023", self.source([("base", "in/R_2023_dlm_001_002.sfx.exe", None, True)], "parts")), "unknown")
        self.assertEqual(self.calls(), "")

    def test_an_unpacked_folder_used_as_it_is(self):
        dist = self.dist("ex/revit2025", applied=["U1.exe"])
        self.assertEqual(self.build("2025", self.p("ex/revit2025/.source"), dist), "unknown")   # no record of U1's build
        self.put("ex/revit2025/.source", read(self.source([("update", "gone/update/U1.exe", "25.5.0.57", False)])))
        self.assertEqual(self.build("2025", self.p("ex/revit2025/.source"), dist), "25.5.0.57")
        self.assertEqual(self.build("2025", self.source([])), "unknown")   # nothing at all

    def test_a_broken_archive_and_a_doctype(self):
        self.put("in/update/U.exe", "x"); self.put("in/update/U.exe.broken", "")
        r = self.tool("expected-build", "2025", self.source([("update", "in/update/U.exe", None, False)]))
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, "unknown", ""))
        self.put("in/update/V.exe", "x")
        self.put("in/update/V.exe.setup.xml", '<?xml version="1.0"?><!DOCTYPE b [<!ENTITY e "25.5.0.57">]>'
                 "<Bundle><Identity><BuildNumber>&e;</BuildNumber></Identity></Bundle>")
        self.assertEqual(self.build("2025", self.source([("update", "in/update/V.exe", None, False)])), "unknown")

    def test_an_internal_error_still_answers(self):
        r = self.tool("expected-build", "2025", self.put("list.json", "[1, 2]"))
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "unknown"))
        self.assertEqual(len(r.stderr.splitlines()), 1)


class Check(Base):
    PKGS = [("A", "x64/A/pkg.A.xml", "ADIX", [("CER", "x64/CER/pkg.cer.xml")]), ("B", "x64/B/pkg.B.xml", "MSI", [])]

    def update(self, rel, packages):
        self.put(rel, "x"); self.put(rel + ".setup.xml", setup_xml("25.5.0.57", packages, targets=["25.0.2.419"]))
        return ("update", rel, "25.5.0.57", False)

    def lines(self, year, sl, dist=None, pkgs="A|B"):
        r = self.tool("check", year, sl, *([dist] if dist else []), "--pkgs", pkgs)
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        return [l.split("\t") for l in r.stdout.splitlines()]

    def test_an_update_package_that_is_new(self):
        dist = self.dist("ex/revit2025", packages=self.PKGS + [("RVTSP", "x64/pkg.RVTSP.xml", "MSP", [])])
        up = self.update("in/update/Revit_2025_5_0.exe", [
            ("A", "x64/A/pkg.A.xml"), ("CER", "x64/CER/pkg.cer.xml"), ("DOTNET100", "3rdParty/x64/dotNet/100/pkg.dotnet100.xml"),
            ("ASPNETCORE100", "3rdParty\\x64\\aspNetCore\\100\\pkg.aspnet100.xml"), ("RVTSP", "x64/pkg.RVTSP.xml"),
            ("RTCA", "x64/RTCA/pkg.RTCA.xml"), ("NEWPKG", "x64/NEW/pkg.NEW.xml")])
        got = self.lines("2025", self.source([up]), dist)
        self.assertEqual(len(got), 1, got)
        self.assertEqual(len(got[0]), 3)
        self.assertEqual(got[0][0], "warn")
        self.assertIn("Revit_2025_5_0.exe", got[0][1]); self.assertIn("NEWPKG", got[0][1])
        for name in ("CER", "DOTNET100", "ASPNETCORE100", "RVTSP", "RTCA", " A,"):
            self.assertNotIn(name, got[0][1])
        self.assertTrue(got[0][2])

    def test_a_package_right_in_x64_that_is_not_an_msp(self):
        dist = self.dist("ex/revit2025", packages=self.PKGS)
        self.put("ex/revit2025/x64/pkg.ODD.xml", pkg_xml("MSI"))
        got = self.lines("2025", self.source([self.update("in/update/U.exe", [("ODD", "x64/pkg.ODD.xml")])]), dist)
        self.assertEqual(len(got), 1); self.assertIn("ODD", got[0][1])

    def test_known_packages_are_per_year(self):
        dist = self.dist("ex/revit2026", packages=self.PKGS)
        up = self.update("in/update/U.exe", [("RTCA", "x64/RTCA/pkg.RTCA.xml"), ("RAIM", "x64/RAIM/pkg.RAIM.xml")])
        self.assertEqual(self.lines("2025", self.source([up]), dist), [])
        got = self.lines("2026", self.source([up]), dist)
        self.assertEqual(len(got), 1); self.assertIn("RTCA, RAIM", got[0][1])

    def test_without_the_unpacked_folder_the_create_installer_lists_the_base(self):
        self.put("in/CI.exe", "x")
        self.put("in/CI.exe.tree/B/setup.xml", setup_xml("27.0.4.412"))
        self.put("in/CI.exe.tree/B/manifest/app.RVT.xml", app_xml([("A", "x64/A/pkg.A.xml")]))
        self.put("in/CI.exe.tree/B/x64/A/pkg.A.xml", pkg_xml(deps=[("IPMClient", "x64/IPM/pkg.ipm.xml")]))
        up = self.update("in/update/U.exe", [("A", "x64/A/pkg.A.xml"), ("IPMClient", "x64/IPM/pkg.ipm.xml"),
                                             ("ASSISTANT", "x64/AI/pkg.AI.xml"), ("MSPATCH", "x64/pkg.P.xml")])
        sl = self.source([("create-installer", "in/CI.exe", None, False), up], "create-installer")
        self.assertEqual(self.lines("2027", sl, pkgs="A"), [])
        got = self.lines("2026", sl, pkgs="A")
        self.assertEqual(len(got), 1); self.assertIn("ASSISTANT", got[0][1]); self.assertNotIn("MSPATCH", got[0][1])

    def test_untested_licensing(self):
        sl = self.source([])
        got = self.lines("2027", sl, self.dist("a", packages=self.PKGS, licensing="17.0.0.16519"))
        self.assertEqual(got, [["warn", "AdskLicensing 17.0 is not tested yet.",
                                "You can continue. If the install stops at licensing, report a problem."]])
        self.assertEqual(self.lines("2027", sl, self.dist("b", packages=self.PKGS, licensing="16.1.0.14849")), [])
        self.assertEqual(self.lines("2020", sl, self.dist("c", packages=self.PKGS, licensing="9.2.2.123", lic_dir="AdskLicensing")), [])

    def test_two_create_installers(self):
        self.put("in/Create_Installer_RVT_2026_5_English_WIN64.exe", "x")
        self.put("in/Create_Installer_RVT_2026_6_English_WIN64.exe", "x")
        sl = self.source([("create-installer", "in/Create_Installer_RVT_2026_6_English_WIN64.exe", None, False)], "create-installer")
        got = self.lines("2026", sl)
        self.assertEqual(len(got), 1)
        self.assertIn("2 Create Installer files", got[0][1]); self.assertIn("Create_Installer_RVT_2026_6_English_WIN64.exe", got[0][1])
        self.assertIn("installers/revit2026/", got[0][2])

    def test_a_pkgs_name_the_installer_lacks(self):
        got = self.lines("2025", self.source([]), self.dist("ex/revit2025", packages=self.PKGS), pkgs="A|B|Gone Away")
        self.assertEqual(len(got), 1); self.assertIn("Gone Away", got[0][1]); self.assertNotIn("B", got[0][1].split(":")[-1])

    def test_nothing_to_say(self):
        self.assertEqual(self.lines("2025", self.source([])), [])
        self.assertEqual(self.lines("2025", self.p("missing.json")), [])
        self.put("in/update/U.exe", "x"); self.put("in/update/U.exe.broken", "")   # a broken archive: no output
        self.assertEqual(self.lines("2025", self.source([("update", "in/update/U.exe", None, False)]),
                                    self.dist("ex/revit2025", packages=self.PKGS)), [])
        self.put("bad/setup.xml", "<Bundle"); self.put("bad/manifest/app.RVT.xml", "<Application><Package")
        self.assertEqual(self.lines("2025", self.source([]), self.p("bad")), [])

    def test_an_internal_error_prints_nothing(self):
        r = self.tool("check", "2025", self.put("list.json", '{"files": {"role": "update"}}'), "--pkgs", "A")
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.assertEqual(len(r.stderr.splitlines()), 1)


class Packages(Base):
    def test_table(self):
        dist = self.dist("ex/revit2028", packages=[("A", "x64/A/pkg.A.xml", "ADIX", []), ("B C", "x64/B/pkg.B.xml", "MSI", [])])
        self.put("ex/revit2028/x64/NEW/pkg.NEW.xml", pkg_xml("ZIP"))
        self.put("in/update/U.exe", "x")
        self.put("in/update/U.exe.setup.xml", setup_xml("28.1.0.1", [("A_RENAMED", "x64/A/pkg.A.xml"), ("NEW", "x64/NEW/pkg.NEW.xml")]))
        self.put("ex/revit2028/.source", read(self.source([("update", "in/update/U.exe", "28.1.0.1", False)])))
        r = self.tool("packages", dist, "--pkgs", "A|Missing")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = [l.split() for l in r.stdout.splitlines()]
        self.assertEqual(rows[0], ["package", "type", "in", "PKGS"])
        self.assertEqual(rows[1:4], [["A", "ADIX", "base+update", "yes"], ["B", "C", "MSI", "base", "no"], ["NEW", "ZIP", "update", "no"]])
        self.assertEqual(r.stdout.splitlines()[-1], "in PKGS, not in this installer: Missing")
        self.assertEqual(self.tool("packages", dist).stdout.splitlines()[0].split(), ["package", "type", "in"])

    def test_without_a_manifest(self):
        os.makedirs(self.p("empty"))
        r = self.tool("packages", self.p("empty"))
        self.assertEqual(r.returncode, 1); self.assertIn("manifest", r.stderr)


class Source(Base):
    """tools/installer_source.py: the Create Installer's manifests parsed in any attribute order, through to the build."""

    def src_tool(self, *a):
        return subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "installer_source.py"), *a],
                              capture_output=True, text=True, env=self.env, cwd="/")

    def test_manifest_in_any_attribute_order_reaches_the_expected_build(self):
        ci = "in/Create_Installer_RVT_2025_5_English_WIN64.exe"
        self.put(ci, "x"); t = ci + ".tree/RVT_2025_en-US"
        self.put(ci + ".tree/collection.xml", '<Collection version="1.4"><Configuration><BrowserImageUrl>'
                 "https://dds.autodesk.com/x/RVT_2025_B_001_002.exe;https://dds.autodesk.com/x/RVT_2025_B_002_002.7z"
                 "</BrowserImageUrl></Configuration></Collection>")
        self.put(f"{t}/setup.xml", setup_xml("25.0.2.419"))
        self.put(f"{t}/manifest/app.RVT.xml", app_xml([("A", "x64/A/pkg.A.xml")]))
        self.put(f"{t}/setup_ext.xml", f'<BundleExtension {NS}><Add><Packages><Package upi2="{{2}}" sourceDir="YOH" '
                 'path="setup.xml" name="Update"><Dependencies><Package upi2="{3}"/></Dependencies></Package></Packages></Add>'
                 "<Replace><Packages/></Replace></BundleExtension>")
        self.put(f"{t}/YOH/setup.xml", f'<Package {NS}><Identity><BuildNumber envvar="X">25.5.0.57</BuildNumber></Identity>'
                 '<Payload sizeUnpacked="9" sizePacked="9"><File sizeUnpacked="9" sizePacked="3655601376" '
                 'checkSum="ABCDEF0123">https://up1.autodesk.com/prd/2025/RVT/U/Revit_2025_5_0.exe</File></Payload></Package>')
        sl = self.p("source.json")
        r = self.src_tool("resolve", "2025", self.p("in"), self.p("dl"), self.p("none.txt"), sl)
        self.assertEqual(r.returncode, 0, r.stderr)
        s = json.loads(read(sl))
        up = [f for f in s["files"] if f["role"] == "update"]
        self.assertEqual([(os.path.basename(f["path"]), f["size"], f["expected_sha256"], f["build"]) for f in up],
                         [("Revit_2025_5_0.exe", 3655601376, "abcdef0123", "25.5.0.57")])
        self.assertIsNone(s["revit_build_expected"])
        self.assertEqual(self.build("2025", sl), "25.5.0.57")

    def test_the_build_is_kept_through_finalize(self):
        self.put("in/RVT_2025_NA_win_db_002_002.zip", "A")
        sl = self.p("source.json")
        self.assertEqual(self.src_tool("resolve", "2025", self.p("in"), self.p("in"), self.p("none.txt"), sl).returncode, 0)
        self.assertEqual(self.src_tool("build", sl, "25.5.0.57").returncode, 0)
        self.assertEqual(self.src_tool("finalize", sl, self.p("h.tsv")).returncode, 0)
        s = json.loads(read(sl))
        self.assertEqual((s["revit_build_expected"], bool(s["source_id"])), ("25.5.0.57", True))
        self.assertEqual(self.src_tool("build", sl, "unknown").returncode, 0)
        self.assertIsNone(json.loads(read(sl))["revit_build_expected"])
        self.assertEqual(self.src_tool("build", self.put("bad.json", "[]"), "1.2.3.4").returncode, 1)


class Preflight(Base):
    """install.sh in a sandbox (a copy of the repo, a fake HOME, CrossOver and tools; every action a stub)."""

    def setUp(self):
        super().setUp()
        self.r = self.p("repo"); os.makedirs(self.r)
        shutil.copy(os.path.join(REPO, "install.sh"), self.r)
        shutil.copytree(os.path.join(REPO, "scripts"), os.path.join(self.r, "scripts"))
        shutil.copytree(os.path.join(REPO, "tools"), os.path.join(self.r, "tools"), ignore=shutil.ignore_patterns("__pycache__"))
        txt = read(os.path.join(self.r, "install.sh"))   # the Mac hardware checks pass in the sandbox
        for a, b in (("sysctl -n hw.optional.arm64", "echo 1"), ("sysctl -n sysctl.proc_translated", "echo 0"),
                     ("/usr/bin/arch -x86_64 /usr/bin/true", "true")):
            txt = txt.replace(a, b)
        write(os.path.join(self.r, "install.sh"), txt)
        for t in ("winetricks", "cabextract"):
            self.put(f"bin/{t}", "#!/bin/bash\nexit 0\n"); os.chmod(os.path.join(self.bin, t), 0o755)
        self.put("cx/bin/cxbottle", "#!/bin/bash\nexit 0\n"); os.chmod(self.p("cx/bin/cxbottle"), 0o755)
        self.put("repo/installers/redist/win7sp1/x64/msls31.dll", "")
        rec = ('#!/bin/bash\nb="$(/usr/bin/perl -MJSON::PP -0 -ne \'print decode_json($_)->{revit_build_expected} // "null"\' '
               '"$REVIT_SOURCE_LIST")"\necho "$(basename "$0") RUNLOG_BUILD=$RUNLOG_BUILD list=$b" >> "%s"\n') % self.p("calls")
        for s in ("get-shims", "get-revit", "get-redist", "unpack-revit", "make-apps"):
            self.put(f"repo/scripts/{s}.sh", rec)
        self.put("repo/scripts/new-bottle.sh", rec + 'mkdir -p "$HOME/Library/Application Support/CrossOver/Bottles/$2/drive_c"\n')
        self.put("repo/scripts/run-steps.sh", rec + 'd="$HOME/Library/Application Support/CrossOver/Bottles/$2/drive_c/Program Files/'
                 'Autodesk/Revit $1"; mkdir -p "$d"; touch "$d/Revit.exe"\n')
        for f in os.listdir(os.path.join(self.r, "scripts")):
            if f.endswith(".sh"):
                os.chmod(os.path.join(self.r, "scripts", f), 0o755)
        self.env["REVIT_CX"] = self.p("cx")
        prof = read(os.path.join(REPO, "scripts", "profiles", "2027.sh"))
        self.pkgs = [(n, f"x64/P{i}/pkg.P{i}.xml") for i, n in enumerate(prof.split('PKGS="', 1)[1].split('"', 1)[0].split("|"))]

    def install(self, *extra):
        return subprocess.run(["/bin/bash", os.path.join(self.r, "install.sh"), "2027", "rvt2027-t"],
                              capture_output=True, text=True, env=dict(self.env, **dict(extra)), cwd="/")

    def create_installer(self, packages):
        ci = "repo/installers/revit2027/Create_Installer_RVT_2027_3_English_WIN64.exe"; t = ci + ".tree/RVT_2027_en-US"
        self.put(ci, "x")
        self.put(ci + ".tree/collection.xml", "<Collection><BrowserImageUrl>https://dds.autodesk.com/x/RVT_2027_B_002_002.7z"
                 "</BrowserImageUrl></Collection>")
        self.put(f"{t}/setup.xml", setup_xml("27.0.4.412"))
        self.put(f"{t}/manifest/app.RVT.xml", app_xml(packages))
        self.put(f"{t}/setup_ext.xml", '<BundleExtension><Add><Packages><Package sourceDir="SGM" name="U"/></Packages></Add></BundleExtension>')
        self.put(f"{t}/SGM/setup.xml", '<Package><Identity><BuildNumber>27.3.0.28</BuildNumber></Identity><Payload><File '
                 'sizePacked="1" checkSum="ab">https://up1.autodesk.com/u/Revit_2027_3_0.exe</File></Payload></Package>')

    def test_the_build_and_the_warnings(self):
        self.create_installer(self.pkgs)
        self.put("repo/installers/revit2027/update/Revit_2027_3_0.exe", "x")
        self.put("repo/installers/revit2027/update/Revit_2027_3_0.exe.setup.xml",
                 setup_xml("27.3.0.28", [("ASSISTANT", "x64/AI/pkg.AI.xml"), ("NEWPKG", "x64/NEW/pkg.NEW.xml")]))
        r = self.install()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        out = r.stdout.splitlines()
        i = next(i for i, l in enumerate(out) if "NEWPKG" in l)
        self.assertTrue(out[i].startswith("  ! The update Revit_2027_3_0.exe adds packages"), out[i])
        self.assertNotIn("ASSISTANT", out[i])
        self.assertTrue(out[i + 1].startswith("      You can continue"), out[i + 1])
        calls = read(self.p("calls"))
        self.assertIn("unpack-revit.sh RUNLOG_BUILD=27.3.0.28 list=27.3.0.28", calls)
        listed = [os.path.join(dp, "source.list") for dp, _, fs in os.walk(self.p("repo/logs")) if "source.list" in fs]
        self.assertEqual(len(listed), 1)
        self.assertEqual(json.loads(read(listed[0]))["revit_build_expected"], "27.3.0.28")

    def test_no_installer_adds_nothing(self):
        r = self.install(("INSTALL_DRYRUN", "1"))
        self.assertIn("no Revit 2027 installer", r.stdout)
        self.assertNotIn("7zz", self.calls())
        for word in ("adds packages", "AdskLicensing", "Create Installer files", "does not have packages"):
            self.assertNotIn(word, r.stdout)

    def test_an_unpacked_folder_used_as_it_is(self):
        self.dist("repo/installers/extracted/revit2027", build="27.0.4.412", packages=[(n, p, "ADIX", []) for n, p in self.pkgs],
                  licensing="17.0.0.16519", applied=["Revit_2027_3_0.exe"])
        self.put("repo/installers/extracted/revit2027/.source",
                 read(self.source([("update", "gone/update/Revit_2027_3_0.exe", "27.3.0.28", False)], name="dot.json")))
        r = self.install(("REVIT_REUSE_EXTRACTED", "1"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual([l for l in r.stdout.splitlines() if l.startswith("  ! ") and "GB free" not in l and "/etc/hosts" not in l],
                         ["  ! AdskLicensing 17.0 is not tested yet."])
        self.assertIn("  ! AdskLicensing 17.0 is not tested yet.\n      You can continue. If the install stops at licensing, report a problem.\n", r.stdout)
        self.assertIn("unpack-revit.sh RUNLOG_BUILD=27.3.0.28", read(self.p("calls")))


if __name__ == "__main__":
    unittest.main()
