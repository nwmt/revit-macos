# SPDX-License-Identifier: MIT
"""The Revit installer source: which files an install reads, downloads and unpacks, and what an unpacked folder was
made from. Resolved once (source.json); get-revit.sh, unpack-revit.sh and install.sh read it.

  resolve  <year> <input> <downloads> <checksums> <out.json>   stage 1: files, roles, URLs, expected sums
  finalize <source.json> <hashes.tsv>                          stage 2: actual sha256, source_id
  compare  <source.json> <dot-source.json> <hashes.tsv>        match | mismatch <why> | nosource
  detect   <folder>                                            for ./revit find-installer

Kinds: create-installer (2024+: Autodesk's small tool and the files its manifest names), parts (an Autodesk multi-part
download, every part in one folder), archive (a base archive without the tool). Updates: the manifest's and every
update/*.exe of both folders, one copy per name. Large files are hashed once per (path, size, mtime in ns)."""
import glob, hashlib, json, os, re, shutil, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

PART = re.compile(r"_(\d{3})_(\d{3})\.sfx\.exe$", re.I)
ARCH = (".7z", ".zip", ".iso")
MAX_XML = 4 << 20   # Autodesk's manifests are 1-20 KB


def xml_root(data):
    """The root element of an Autodesk manifest, from bytes or a file path; tag names without their namespace. A
    DOCTYPE (entities) is refused; a file that does not parse is a ValueError."""
    if isinstance(data, str):
        with open(data, "rb") as f:
            data = f.read(MAX_XML + 1)
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        head = data.decode("utf-16", "replace")
    else:
        head = data.decode("utf-16-le" if data[:2] == b"<\0" else "utf-8", "replace")
    if len(data) > MAX_XML or "<!DOCTYPE" in head or "<!ENTITY" in head:
        raise ValueError("not an installer manifest")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise ValueError(f"not an installer manifest ({e})")
    for e in root.iter():
        if isinstance(e.tag, str) and "}" in e.tag:
            e.tag = e.tag.rsplit("}", 1)[1]
    return root


def build_number(root):
    """The BuildNumber of a manifest's own Identity (an update also lists the builds it applies to), else the first."""
    e = root.find("Identity/BuildNumber")
    if e is None:
        e = next(root.iter("BuildNumber"), None)
    t = (e.text or "").strip() if e is not None else ""
    return t or None


def natural(name):   # the order of sort -V for these names
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", name)]


def entry(role, path, url=None, size=None, exp=None, build=None):
    return {"role": role, "path": path, "url": url, "size": size, "expected_sha256": exp, "sha256": None,
            "extract": False, "build": build}


def expected_sums(checksums, year):
    out = {}
    if os.path.exists(checksums):
        for line in open(checksums, encoding="utf-8"):
            p = line.split()
            if len(p) >= 2 and p[1].startswith(f"revit{year}/"):
                out[p[1].split("/")[-1]] = p[0].lower()
    return out


def manifest(ci):
    """(base URLs, updates as (url, size, sha256, build)) of a Create Installer, read with 7zz. The XML is parsed:
    Autodesk's manifests put attributes in any order."""
    tmp = tempfile.mkdtemp()
    try:
        subprocess.run(["7zz", "x", "-y", "-o" + tmp, ci, "collection.xml", "bootstrap.json", "*/setup_ext.xml", "*/*/setup.xml"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        col = os.path.join(tmp, "collection.xml")
        if not os.path.exists(col):
            raise SystemExit(f"{os.path.basename(ci)}: no collection.xml inside — not an Autodesk Create Installer?")
        urls = next((e.text or "" for e in xml_root(col).iter("BrowserImageUrl")), "")
        base = [u for u in urls.split(";") if u.strip()]
        if not base:
            raise SystemExit(f"{os.path.basename(ci)}: lists no full installer (BrowserImageUrl) — please report this")
        ups = []
        for ext in glob.glob(os.path.join(tmp, "*", "setup_ext.xml")):
            for d in [p.get("sourceDir") for p in xml_root(ext).iter("Package") if p.get("sourceDir")]:
                s = xml_root(os.path.join(os.path.dirname(ext), d, "setup.xml"))
                b = build_number(s) or "?"
                pay = next(s.iter("Payload"), None)
                for f in pay.iter("File") if pay is not None else ():
                    c, n, u = f.get("checkSum", ""), f.get("sizePacked", ""), (f.text or "").strip()
                    if re.fullmatch(r"\w+", c) and n.isdigit() and u:
                        ups.append((u, int(n), c.lower(), b))
        return base, ups
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def find_parts(dirs):
    """(complete parts, first incomplete parts): a complete set in input, then in downloads; any part names a set."""
    incomplete = None
    for d in dirs:
        groups = {}
        for p in glob.glob(os.path.join(d, "*.sfx.exe")):
            m = PART.search(p)
            if m:
                groups.setdefault((p[: m.start()], int(m.group(2))), set()).add(int(m.group(1)))
        for (stem, total), have in sorted(groups.items()):
            parts = [f"{stem}_{i:03d}_{total:03d}.sfx.exe" for i in range(1, total + 1)]
            if len(have) == total:
                return parts, None
            incomplete = incomplete or parts
    return None, incomplete


def local_updates(dirs, sums):   # every copy, each with its known sum (CHECKSUMS.txt), checked before canonical()
    return [entry("update", p, None, None, sums.get(os.path.basename(p))) for d in dirs for p in glob.glob(os.path.join(d, "update", "*.exe"))]


def ordered(files):   # base as given, then updates as sort -V orders their names
    base = [f for f in files if f["role"] != "update"]
    ups = sorted((f for f in files if f["role"] == "update"), key=lambda f: natural(os.path.basename(f["path"])))
    return base + ups


def resolve(year, inp, dl, checksums):
    sums = expected_sums(checksums, year)
    dirs = [inp] if os.path.realpath(inp) == os.path.realpath(dl) else [inp, dl]
    s = {"year": year, "kind": None, "manifest_id": None, "problem": "", "files": [], "source_id": None, "unknown": []}
    cis = sorted(glob.glob(os.path.join(inp, f"Create_Installer_RVT_{year}_*.exe")), key=natural)
    if cis:
        ci = cis[-1]
        base, ups = manifest(ci)
        names = [os.path.basename(u) for u in base]
        home = next((d for d in dirs if all(os.path.exists(os.path.join(d, n)) for n in names)), dl)
        files = [entry("create-installer", ci)]
        files += [entry("base", os.path.join(home, os.path.basename(u)), u, None, sums.get(os.path.basename(u))) for u in base]
        listed = set()
        for u, n, c, b in ups:   # every local copy (canonical() merges equal ones, refuses different ones)
            name = os.path.basename(u); listed.add(name)
            copies = [os.path.join(d, "update", name) for d in dirs if os.path.exists(os.path.join(d, "update", name))]
            for path in copies or [os.path.join(dl, "update", name)]:
                files.append(entry("update", path, u, n, c, b))
        files += [f for f in local_updates(dirs, sums) if os.path.basename(f["path"]) not in listed]
        s["kind"] = "create-installer"
        s["manifest_id"] = hashlib.sha256(("\n".join([sha_file(ci)] + names + sorted(listed))).encode()).hexdigest()
        s["files"] = ordered(files)
    else:
        parts, partial = find_parts(dirs)
        if parts or partial:
            s["kind"] = "parts"
            s["files"] = ordered([entry("base", p, None, None, sums.get(os.path.basename(p))) for p in (parts or partial)] + local_updates(dirs, sums))
        else:
            arch = next((a for d in dirs for a in [sorted((p for p in glob.glob(os.path.join(d, "*")) if p.lower().endswith(ARCH)),
                                                          key=os.path.getsize)] if a), None)
            if arch:
                s["kind"] = "archive"
                s["files"] = ordered([entry("base", arch[-1], None, None, sums.get(os.path.basename(arch[-1])))] + local_updates(dirs, sums))
            else:
                boot = [p for d in dirs for p in glob.glob(os.path.join(d, "*_001_00[0-9].exe"))]
                if boot and local_updates(dirs, sums):   # downloader without payload, and updates: the updates
                    # still count for an unpacked folder; a fresh install still hears about the missing payload
                    s["kind"] = "updates-only"; s["problem"] = "payload"; s["files"] = ordered(local_updates(dirs, sums))
                elif boot:   # a downloader whose payload (.7z) is missing
                    s["kind"] = "archive"; s["problem"] = "payload"; s["files"] = [entry("base", boot[0])]
                elif local_updates(dirs, sums):   # the base is gone, updates are left: never enough for a fresh
                    # unpack (no base, so no source_id), but checked, compared and laid on an unpacked folder
                    s["kind"] = "updates-only"; s["files"] = ordered(local_updates(dirs, sums))
    mark_extract(s)
    return s


def mark_extract(s):
    base = [f for f in s["files"] if f["role"] == "base"]
    if not base or s["problem"]:
        return
    first = next((f for f in base if PART.search(f["path"]) and PART.search(f["path"]).group(1) == "001"), None)
    pick = first or next((f for f in base if f["path"].lower().endswith(ARCH)), None) or base[-1]
    pick["extract"] = True


def sha_file(p, cache=None):
    st = os.stat(p); key = f"{p}\t{st.st_size}\t{st.st_mtime_ns}"
    if cache is not None and key in cache:
        return cache[key]
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    if cache is not None:
        cache[key] = h.hexdigest()
    return h.hexdigest()


def load_cache(path):
    c = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            p = line.rstrip("\n").rsplit("\t", 1)
            if len(p) == 2:
                c[p[0]] = p[1]
    return c


def save_cache(path, c):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.new.{os.getpid()}"   # a temporary file per writer: two runs may save at once
    with open(tmp, "w", encoding="utf-8") as f:
        for k, v in c.items():
            f.write(f"{k}\t{v}\n")
    os.replace(tmp, path)


class Conflict(Exception):
    pass


def canonical(files):
    """One copy per update name (equal sha256 merged, different ones a Conflict), in the resolved order."""
    out, seen = [], {}
    for f in files:
        if f["role"] != "update":
            out.append(f); continue
        n = os.path.basename(f["path"])
        if n in seen:
            o = seen[n]
            if o["sha256"] and f["sha256"] and o["sha256"] != f["sha256"]:
                raise Conflict(f"two different updates named {n}: {o['path']} and {f['path']}")
            if not o["sha256"] and f["sha256"]:
                out[out.index(o)] = f; seen[n] = f
            continue
        seen[n] = f; out.append(f)
    return out


def identity(kind, files):
    return hashlib.sha256(json.dumps([kind] + [[f["role"], os.path.basename(f["path"]), f["sha256"]] for f in files]).encode()).hexdigest()


def finalize(src, hashes):
    s = json.load(open(src)); cache = load_cache(hashes)
    try:
        for f in s["files"]:
            if not os.path.exists(f["path"]):
                continue
            if f["expected_sha256"]:
                print(f">> checking {os.path.basename(f['path'])}", flush=True)
            f["sha256"] = sha_file(f["path"], cache)
            if f["expected_sha256"] and f["expected_sha256"] != f["sha256"]:
                sys.stderr.write(f"!! {os.path.basename(f['path'])}: checksum mismatch; delete it and run again\n"); return 4
        s["files"] = canonical(s["files"])
    except Conflict as e:
        sys.stderr.write(f"!! {e}\n"); return 4
    finally:
        save_cache(hashes, cache)
    s["unknown"] = [os.path.basename(f["path"]) for f in s["files"] if f["sha256"] and not f["expected_sha256"] and f["role"] != "create-installer"]
    s["source_id"] = (identity(s["kind"], s["files"]) if s["kind"] != "updates-only" and s["files"]
                      and all(f["sha256"] for f in s["files"]) else None)
    json.dump(s, open(src, "w"), indent=1)
    return 0


def compare(src, dot, hashes):
    s = json.load(open(src)); d = json.load(open(dot)); cache = load_cache(hashes)
    try:
        for f in s["files"]:
            if os.path.exists(f["path"]):
                f["sha256"] = sha_file(f["path"], cache)
        files = canonical(s["files"])
    finally:
        save_cache(hashes, cache)
    present = [f for f in files if f["sha256"]]
    if not present:
        return "nosource"
    if len(present) == len(files) and s["kind"] != "updates-only":
        return "match" if identity(s["kind"], files) == d.get("source_id") else "mismatch the installer files differ from the unpacked ones"
    if s["kind"] != "updates-only":   # base files missing: only a Create Installer still says which base it was
        if not s.get("manifest_id"):
            return "mismatch installer files are missing"
        if s["manifest_id"] != d.get("manifest_id"):
            return "mismatch another Create Installer"
    old = {(f["role"], os.path.basename(f["path"])): f.get("sha256") for f in d.get("files", [])}
    for f in present:
        k = (f["role"], os.path.basename(f["path"]))
        if old.get(k) != f["sha256"]:
            return f"mismatch {k[1]} is new or changed"
    have = {os.path.basename(f["path"]) for f in present if f["role"] == "update"}
    for (role, name) in old:
        if role == "update" and name not in have:
            return f"mismatch {name} is gone"
    return "match"


def detect(folder):
    names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    year = next((m.group(1) for n in names for m in [re.search(r"(?:Create_Installer_RVT_|Revit_|RVT_)(\d{4})_", n)] if m), None)
    out = {"year": year, "kind": None, "complete": False, "downloadable": False, "missing": [], "problem": "", "files": []}
    if not year:
        return out
    s = resolve(year, folder, folder, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "installers", "CHECKSUMS.txt"))
    absent = [f for f in s["files"] if not os.path.exists(f["path"])]
    out.update(kind=s["kind"], problem=s["problem"], missing=[os.path.basename(f["path"]) for f in absent])
    out["complete"] = bool(s["files"]) and not absent and not s["problem"] and s["kind"] != "updates-only"
    out["downloadable"] = bool(absent) and all(f["url"] for f in absent)
    for f in s["files"]:
        if os.path.exists(f["path"]):
            chk = "unknown"
            if f["expected_sha256"]:
                chk = "known" if sha_file(f["path"]) == f["expected_sha256"] else "mismatch"
            out["files"].append({"name": os.path.basename(f["path"]), "check": chk})
    return out


def main(a):
    try:
        if a[:1] == ["resolve"] and len(a) == 6:
            s = resolve(a[1], a[2], a[3], a[4]); json.dump(s, open(a[5], "w"), indent=1)
            if not s["files"]:
                sys.stderr.write(f"no Revit {a[1]} installer in {a[2]}\n"); return 3
            done = all(os.path.exists(f["path"]) for f in s["files"]) and not s["problem"] and s["kind"] != "updates-only"
            print(f"kind={s['kind']} complete={int(done)}"); return 0
        if a[:1] == ["finalize"] and len(a) == 3:
            return finalize(a[1], a[2])
        if a[:1] == ["compare"] and len(a) == 4:
            print(compare(a[1], a[2], a[3])); return 0
        if a[:1] == ["detect"] and len(a) == 2:
            print(json.dumps(detect(a[1]))); return 0
    except Conflict as e:
        sys.stderr.write(f"!! {e}\n"); return 4
    except (OSError, ValueError) as e:
        sys.stderr.write(f"!! {e}\n"); return 1
    sys.stderr.write(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
