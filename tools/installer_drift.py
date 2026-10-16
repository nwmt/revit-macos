#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The Revit build an install lays down, and where the installer differs from what this project knows.

  installer_drift.py expected-build <year> <source.json> [<dist>]          a.b.c.d, or unknown
  installer_drift.py check <year> <source.json> [<dist>] --pkgs "<PKGS>"   warn<TAB>text<TAB>what to do, per difference
  installer_drift.py packages <dist> [--pkgs "<PKGS>"]                     the packages of an unpacked installer

<source.json> is the list tools/installer_source.py resolves (missing or unreadable: no files). <dist> is an unpacked
installer root (revit_dist in scripts/lib/versions.sh). With it, that folder is what gets installed: its setup.xml and
packages, and the updates of its applied-updates.txt besides the list's. Without it: the Create Installer's own
manifests, each update's setup.xml, and the base archive only when no update gives a build (one small file of a solid
11 GB archive takes 4-5 s; of an update, 0.01 s). A Setup.ini installer (2020) has no build: unknown.

check prints a line only for what the code does not know: a PKGS name the installer lacks, an update package that is
not installed and not in KNOWN, an AdskLicensing outside LICENSING_TESTED (of the unpacked folder: the Create
Installer's own licensing package is not what gets installed), two or more Create Installers, with what to do for each.
It never stops an install: an internal error prints nothing on stdout, one line on stderr, and exits 0.
Every XML file is parsed (attributes come in any order). Nothing is written but a temporary folder.
Run with python3 -I -B.
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installer_source as source  # noqa: E402

# packages an update adds that this project knowingly does not install (versions/<year>.md, Known issues)
KNOWN = {"2024": {"RTCA"}, "2025": {"RTCA", "RAIM"}, "2027": {"ASSISTANT"}}
LICENSING_TESTED = ("9.2", "13.1", "14.0", "15.0", "16.1")   # AdskLicensing major.minor that real installs got through
# update packages a step installs anyway: step dotnet takes every runtime in these folders
STEP_DOTNET = re.compile(r"^3rdparty/x64/(dotnet|aspnetcore)/")
MSP_HOME = re.compile(r"^x64/pkg\.[^/]+\.xml$")   # where step rvt looks for an MSP patch of RVT.msi
TIMEOUT = 120


def key(b):
    return tuple(int(x) for x in b.split("."))


def valid(b):
    return b if isinstance(b, str) and source.BUILD.match(b) else None


def norm(p):   # a package path as the manifests write it → a comparable one
    p = p.replace("\\", "/").lower()
    return p[2:] if p.startswith("./") else p


def inside(root, p):   # a manifest's relative path → a file under root (None for an absolute path or one with ..)
    parts = p.replace("\\", "/").split("/")
    return None if p.startswith(("/", "\\")) or ".." in parts else os.path.join(root, *parts)


def parse(data):
    """A manifest (bytes or path) → root element, or None when it is missing, too big or does not parse."""
    if data is None:
        return None
    try:
        return source.xml_root(data)
    except (OSError, ValueError):
        return None


def source_build(root):
    return source.build_number(root) if root is not None else None


def member(archive, name):
    """One small file out of an archive (7zz e -so), or None. -t7z finds the 7z inside an update's .exe at once; without
    it 7zz first reads the whole PE (10 s for 3.6 GB)."""
    typed = ["-t7z"] if archive.lower().endswith((".7z", ".exe")) else []
    try:
        r = subprocess.run(["7zz", "e", "-so"] + typed + [archive, name], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 and r.stdout else None


def load_source(path):
    try:
        with open(path, encoding="utf-8") as f:
            s = json.load(f)
    except (OSError, ValueError):
        return {"files": []}
    if not isinstance(s, dict) or not isinstance(s.get("files", []), list):
        raise ValueError(f"{os.path.basename(path)}: not a source list")
    return s


def files(s, role):
    return [f for f in s.get("files") or [] if isinstance(f, dict) and f.get("role") == role and f.get("path")]


class Reader:
    """Reads each archive member and Create Installer once per run; the temporary folder goes in close()."""

    def __init__(self):
        self.tmp = None
        self.cis = {}
        self.members = {}

    def close(self):
        if self.tmp:
            shutil.rmtree(self.tmp, ignore_errors=True)

    def member(self, archive, name):
        if (archive, name) not in self.members:
            self.members[(archive, name)] = member(archive, name) if os.path.isfile(archive) else None
        return self.members[(archive, name)]

    def bundle(self, ci):
        """The folder of a Create Installer's own product manifests (its XML files, unpacked: 0.1 s), or None."""
        if ci not in self.cis:
            self.cis[ci] = None
            if os.path.isfile(ci):
                self.tmp = self.tmp or tempfile.mkdtemp(prefix="revit-drift.")
                out = os.path.join(self.tmp, str(len(self.cis)))
                try:
                    subprocess.run(["7zz", "x", "-y", "-o" + out, ci, "-r", "*.xml"], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=TIMEOUT)
                except (OSError, subprocess.TimeoutExpired):
                    pass
                dirs = sorted(d for d in glob.glob(os.path.join(out, "*", ""))
                              if os.path.isfile(os.path.join(d, "setup.xml")) and glob.glob(os.path.join(d, "manifest", "app.*.xml")))
                self.cis[ci] = dirs[0].rstrip("/") if dirs else None
        return self.cis[ci]


def updates(s, dist):
    """The updates an install lays down, in order, as (name, path or None, build or None): the list's, one per name,
    then the names an unpacked folder records as applied that the list does not have."""
    out, seen = [], set()
    for f in files(s, "update"):
        n = os.path.basename(f["path"])
        if n not in seen:
            seen.add(n); out.append((n, f["path"], valid(f.get("build"))))
    if dist:
        try:
            with open(os.path.join(dist, "applied-updates.txt"), encoding="utf-8", errors="replace") as f:
                applied = [x.strip() for x in f if x.strip()]
        except OSError:
            applied = []
        for n in applied:
            if n not in seen:
                seen.add(n); out.append((n, None, None))
    return out


def expected_build(s, dist, rd):
    """The highest BuildNumber of the base and of each update, or None. An update always carries a later build than the
    base it applies to: the base archive is opened only when there is no update; an update of unknown build makes the
    whole answer unknown."""
    builds = []
    for _, path, b in updates(s, dist):
        b = b or (path and valid(source_build(parse(rd.member(path, "setup.xml")))))
        if not b:
            return None
        builds.append(b)
    if dist:
        if not os.path.isfile(os.path.join(dist, "setup.xml")):
            return None   # Setup.ini (2020): the installer names no build
        builds.append(valid(source_build(parse(os.path.join(dist, "setup.xml")))))
    else:
        ci = next((f["path"] for f in files(s, "create-installer")), None)
        root = rd.bundle(ci) if ci else None   # the Create Installer's setup.xml describes the base it downloads
        b = valid(source_build(parse(os.path.join(root, "setup.xml")))) if root else None
        if not b and not builds:
            arch = next((f["path"] for f in files(s, "base") if f.get("extract")), None)
            if arch and not source.PART.search(arch):   # a multi-part download is not an archive 7zz reads
                b = valid(source_build(parse(rd.member(arch, "setup.xml"))))
        builds.append(b)
    builds = [b for b in builds if b]
    return max(builds, key=key) if builds else None


def app_packages(root):
    """[(name, path)] of the packages of an installer root's manifest/app.*.xml (those tools/odis.py lists), or None
    without one."""
    apps = sorted(glob.glob(os.path.join(root, "manifest", "app.*.xml")))
    roots = [parse(a) for a in apps]
    if not roots or any(r is None for r in roots):
        return None
    return [(p.get("name") or p.get("path"), p.get("path")) for r in roots for p in r.iter("Package") if p.get("path")]


def base_paths(root):
    """The package paths an installer root knows: its app manifest's and their dependencies (step pkgs installs only
    some of them, but what a base already has is no news); None without an app manifest."""
    top = app_packages(root)
    if top is None:
        return None
    out = set()
    for _, path in top:
        out.add(norm(path))
        f = inside(root, path)
        pkg = parse(f) if f and os.path.isfile(f) else None
        for d in pkg.iter("Package") if pkg is not None else ():
            if d is not pkg and d.get("path"):
                out.add(norm(d.get("path")))
    return out


def update_packages(data):
    """[(name, path)] that an update's setup.xml lists, or None when it cannot be read."""
    r = parse(data)
    if r is None:
        return None
    pk = r.find("Packages")
    return [(p.get("name") or p.get("path"), p.get("path")) for p in (pk.findall("Package") if pk is not None else [])
            if p.get("path")]


def install_type(root, path):
    f = inside(root, path)
    pkg = parse(f) if f and os.path.isfile(f) else None
    e = next(pkg.iter("InstallFile"), None) if pkg is not None else None
    return e.get("type") if e is not None and e.get("type") else None


def licensing(dist):
    """The AdskLicensing BuildNumber of an unpacked installer, or None."""
    for f in sorted(glob.glob(os.path.join(dist, "x86", "Licensing", "pkg.*.xml")) +
                    glob.glob(os.path.join(dist, "x86", "AdskLicensing", "pkg.*.xml"))):
        b = source_build(parse(f))
        if b:
            return b
    return None


def flat(t):
    return re.sub(r"[\t\r\n]+", " ", str(t))


def check(year, s, dist, pkgs, rd):
    """[(text, what to do)] for what this project does not know about the installer."""
    out = []
    ci = next((f["path"] for f in files(s, "create-installer")), None)
    root = dist or (rd.bundle(ci) if ci else None)   # a Create Installer lists the base's own product packages
    top = app_packages(root) if root else None
    gone = [n for n in pkgs or [] if n not in {name for name, _ in top}] if top is not None else []
    if gone:
        out.append((f"The Revit {year} installer does not have packages that this project installs: {', '.join(gone)}.",
                    "The install may stop or leave parts of Revit out. Report a problem."))
    base = base_paths(root) if top is not None else None
    if base is not None:
        for n, path, _ in updates(s, dist):
            ups = update_packages(rd.member(path, "setup.xml")) if path else None
            new = []
            for name, p in ups or []:
                q = norm(p)
                if q in base or STEP_DOTNET.match(q) or name in KNOWN.get(year, ()):
                    continue
                if MSP_HOME.match(q) and (not dist or install_type(dist, p) in (None, "MSP")):
                    continue   # step rvt applies it (without the unpacked folder its type is not known yet)
                new.append(name)
            if new:
                out.append((f"The update {n} adds packages that are not installed: {', '.join(new)}.",
                            "You can continue: the other packages install as before. Report a problem so that they can be added."))
    v = licensing(dist) if dist else None
    if v and ".".join(v.split(".")[:2]) not in LICENSING_TESTED:
        out.append((f"AdskLicensing {'.'.join(v.split('.')[:2])} is not tested yet.",
                    "You can continue. If the install stops at licensing, report a problem."))
    if ci:
        cis = sorted(glob.glob(os.path.join(os.path.dirname(ci), f"Create_Installer_RVT_{year}_*.exe")), key=source.natural)
        if len(cis) > 1:
            out.append((f"installers/revit{year}/ has {len(cis)} Create Installer files; this install uses {os.path.basename(ci)}.",
                        f"To use another one, keep only that one in installers/revit{year}/."))
    return [(flat(t), flat(w)) for t, w in out]


def packages(dist, pkgs, rd):
    """Lines of a table: package, type, in (base, update, base+update), in PKGS; then the PKGS names the base lacks."""
    top = app_packages(dist)
    if top is None:
        raise ValueError(f"no manifest/app.*.xml in {dist}")
    s = next((load_source(p) for p in (os.path.join(dist, ".source"), os.path.join(os.path.dirname(dist), ".source"))
              if os.path.isfile(p)), {"files": []})
    upd = {}
    for _, path, _ in updates(s, dist):
        for name, p in (update_packages(rd.member(path, "setup.xml")) if path else None) or []:
            upd.setdefault(norm(p), (name, p))
    rows, seen = [], set()
    for name, p in top:
        seen.add(norm(p))
        rows.append((name, install_type(dist, p) or "?", "base+update" if norm(p) in upd else "base", name))
    for q, (name, p) in upd.items():
        if q not in seen:
            rows.append((name, install_type(dist, p) or "?", "update", name))
    head = ("package", "type", "in") + (("PKGS",) if pkgs is not None else ())
    table = [head] + [r[:3] + (("yes" if r[3] in pkgs else "no",) if pkgs is not None else ()) for r in rows]
    w = [max(len(flat(r[i])) for r in table) for i in range(len(head))]
    lines = ["  ".join(flat(c).ljust(w[i]) for i, c in enumerate(r)).rstrip() for r in table]
    missing = [n for n in pkgs or [] if n not in {name for name, _ in top}]
    if missing:
        lines.append("in PKGS, not in this installer: " + ", ".join(missing))
    return lines


def args(a):
    """(positional, PKGS names or None)"""
    pos, pkgs, i = [], None, 0
    while i < len(a):
        if a[i] == "--pkgs" and i + 1 < len(a):
            pkgs = [n for n in a[i + 1].split("|") if n]; i += 2
        else:
            pos.append(a[i]); i += 1
    return pos, pkgs


def main(a):
    cmd, (pos, pkgs) = (a[0] if a else ""), args(a[1:])
    rd = Reader()
    try:
        if cmd == "expected-build" and len(pos) in (2, 3):
            try:
                dist = pos[2] if len(pos) == 3 and os.path.isdir(pos[2]) else None
                print(expected_build(load_source(pos[1]), dist, rd) or "unknown")
            except Exception as e:   # never in the way of an install
                sys.stderr.write(f"installer_drift.py: {flat(e) or type(e).__name__}\n"); print("unknown")
            return 0
        if cmd == "check" and len(pos) in (2, 3):
            try:
                dist = pos[2] if len(pos) == 3 and os.path.isdir(pos[2]) else None
                lines = check(pos[0], load_source(pos[1]), dist, pkgs, rd)
            except Exception as e:   # never in the way of an install: no half list either
                sys.stderr.write(f"installer_drift.py: {flat(e) or type(e).__name__}\n"); return 0
            for t, w in lines:
                print(f"warn\t{t}\t{w}")
            return 0
        if cmd == "packages" and len(pos) == 1:
            try:
                print("\n".join(packages(pos[0], pkgs, rd)))
            except (OSError, ValueError) as e:
                sys.stderr.write(f"installer_drift.py: {flat(e)}\n"); return 1
            return 0
    finally:
        rd.close()
    sys.stderr.write(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
