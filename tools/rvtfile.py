#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""What ./revit open needs to know about a Revit file, read on the Mac, without Revit.
  rvtfile.py info <file>             JSON: format (year or null), build, worksharing, size, mtime_ns, error. Exit 1 on error.
  rvtfile.py winpath <bottle> <file> the file's Windows path in the bottle. Exit 1, with the reason, when it has none.
  rvtfile.py copy <file> <year>      a copy beside the file, "<name> (Revit <year>).<ext>"; prints its path. Exit 1 on error.
  rvtfile.py plan <file> <supported years, comma> [<bottle>] [<copy year>]   what ./revit open does with it, as JSON. Stdin:
                                     one "<year> <bottle> <running 0|1>" per bottle that has Revit.
A .rvt, .rfa, .rte or .rft is an OLE2 compound file; its stream BasicFileInfo holds the version as text, UTF-16LE after a
binary part, so the text may start on an odd byte. The labels are not translated. Since 2019: "Format: 2021". 2016 to
2018: "Revit Build: Autodesk Revit 2017 (Build: …)". Much older files name a build only, no year: format is null then.
Only the sectors of that stream are read."""
import json, os, re, stat, struct, subprocess, sys, tempfile

MAGIC = bytes.fromhex("d0cf11e0a1b11ae1")
END = 0xFFFFFFFE          # sector numbers from here on are not sectors
MAX_STREAM = 1 << 20      # BasicFileInfo is a few KB: anything larger is not one
FORBIDDEN = set('\\<>:"|?*')   # legal in a Mac name, not in a Windows one


class Bad(Exception):
    pass


def compound_stream(f, want):
    """The bytes of stream `want` of the compound file f, opened for reading."""
    h = f.read(512)
    if len(h) < 512 or h[:8] != MAGIC:
        raise Bad("not a Revit file")
    shift, mini_shift = struct.unpack("<HH", h[30:34])
    if shift not in (9, 12) or mini_shift != 6:
        raise Bad("damaged file")
    ss, ms = 1 << shift, 1 << mini_shift
    nfat, dir0 = struct.unpack("<I", h[44:48])[0], struct.unpack("<I", h[48:52])[0]
    cutoff, mfat0, _, dif, _ = struct.unpack("<5I", h[56:76])
    total = max(os.fstat(f.fileno()).st_size // ss, 1)

    def sector(n):
        if n >= total:
            raise Bad("damaged file")
        f.seek((n + 1) * ss)
        s = f.read(ss)
        if len(s) < ss:
            raise Bad("damaged file")
        return s

    words = ss // 4
    difat = list(struct.unpack("<109I", h[76:512]))
    visited = set()
    while dif < END:
        if dif in visited:
            raise Bad("damaged file")
        visited.add(dif)
        v = struct.unpack("<%dI" % words, sector(dif))
        difat += v[:-1]
        dif = v[-1]
    fat_sectors = [x for x in difat[:nfat] if x < END]
    fat_cache = {}

    def next_in(fat_list, n):
        i, o = n // words, n % words
        if i >= len(fat_list):
            raise Bad("damaged file")
        k = fat_list[i]
        if k not in fat_cache:
            fat_cache[k] = struct.unpack("<%dI" % words, sector(k))
        return fat_cache[k][o]

    def chain(n, fat_list):
        out, seen = [], set()
        while n < END:
            if n in seen:
                raise Bad("damaged file")
            seen.add(n)
            out.append(n)
            n = next_in(fat_list, n)
        return out

    entry, root = None, None
    for s in chain(dir0, fat_sectors):
        d = sector(s)
        for i in range(0, ss, 128):
            e = d[i:i + 128]
            n = struct.unpack("<H", e[64:66])[0]
            if not 2 <= n <= 64:
                continue
            name, kind = e[:n - 2].decode("utf-16-le", "replace"), e[66]
            start, size = struct.unpack("<I", e[116:120])[0], struct.unpack("<Q", e[120:128])[0]
            if kind == 5:
                root = (start, size)
            elif kind == 2 and name == want and entry is None:
                entry = (start, size)
    if entry is None:
        raise Bad("not a Revit file")
    start, size = entry
    if size > MAX_STREAM:
        raise Bad("not a Revit file")
    if size >= cutoff:
        return b"".join(sector(s) for s in chain(start, fat_sectors))[:size]
    if root is None:
        raise Bad("damaged file")
    mini_fat = chain(mfat0, fat_sectors)
    mini_sectors = chain(root[0], fat_sectors)
    per = ss // ms
    out = bytearray()
    for n in chain(start, mini_fat):
        i, o = n // per, n % per
        if i >= len(mini_sectors):
            raise Bad("damaged file")
        out += sector(mini_sectors[i])[o * ms:(o + 1) * ms]
    return bytes(out[:size])


def facts(data):
    """(format, build, worksharing) from the stream's text; format is None when it names no year."""
    year, build, share = None, "", ""
    for t in (data.decode("utf-16-le", "ignore"), data[1:].decode("utf-16-le", "ignore")):
        m = re.search(r"(?:^|[\r\n])Format: (\d{4})\s", t) \
            or re.search(r"(?:^|[\r\n])Revit Build: Autodesk Revit[^0-9\r\n]*(\d{4})\s", t)
        if m and year is None:
            year = int(m.group(1))
        m = re.search(r"Build: (\d{8}_\d{4})", t)
        if m and not build:
            build = m.group(1)
        m = re.search(r"Worksharing: ([^\r\n]*)", t)
        if m and not share:
            share = m.group(1).strip()
    return year, build, share


def info(path):
    r = {"format": None, "build": "", "worksharing": "", "size": 0, "mtime_ns": 0, "error": ""}
    try:
        with open(path, "rb") as f:
            st = os.fstat(f.fileno())
            r["size"], r["mtime_ns"] = st.st_size, st.st_mtime_ns
            r["format"], r["build"], r["worksharing"] = facts(compound_stream(f, "BasicFileInfo"))
    except Bad as e:
        r["error"] = str(e)
    except (OSError, struct.error) as e:
        r["error"] = getattr(e, "strerror", None) or "damaged file"
    return r


def windows_problem(path):
    """Why this Mac path has no faithful Windows path, or "". a\\b.rvt is one Mac name but two Windows components: it
    would reach another file, of another version."""
    for part in path.split("/"):
        bad = sorted(c for c in set(part) if c in FORBIDDEN or ord(c) < 32)
        if bad:
            shown = " ".join(repr(c)[1:-1] for c in bad)
            return "Windows programs cannot open a file with %s in its path: \"%s\". Rename it first." % (shown, part)
        if part != part.rstrip(". "):
            return "Windows programs cannot open a name that ends in a dot or a space: \"%s\". Rename it first." % part
    return ""


def winpath(bottle, path):
    """path as the bottle sees it: the drive of dosdevices with the longest match (G: for Google Drive, not Z:)."""
    real = os.path.realpath(path)
    problem = windows_problem(real)
    if problem:
        raise Bad(problem)
    d, best, letter = os.path.join(bottle, "dosdevices"), "", ""
    for n in sorted(os.listdir(d)):
        if not re.fullmatch(r"[a-z]:", n):
            continue
        t = os.path.realpath(os.path.join(d, n))
        if real.startswith(t.rstrip("/") + "/") and len(t) > len(best):
            best, letter = t, n
    if not letter:
        raise Bad("The bottle has no drive for this file.")
    return letter.upper() + "\\" + real[len(best):].strip("/").replace("/", "\\")


def copy(path, year):
    """The copy under a name nothing else holds: the name is taken with O_EXCL, the bytes arrive through a temporary
    file renamed over it, so nobody sees a part of a copy and two runs never share one."""
    folder, name = os.path.split(os.path.realpath(path))
    stem, ext = os.path.splitext(name)
    for n in range(1, 100):
        dest = os.path.join(folder, "%s (Revit %d%s)%s" % (stem, year, "" if n == 1 else " %d" % n, ext))
        try:
            os.close(os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, stat.S_IRUSR | stat.S_IWUSR))
            break
        except FileExistsError:
            continue
        except OSError as e:
            raise Bad("Cannot write in %s: %s." % (folder, e.strerror))
    else:
        raise Bad("Too many copies of %s here." % name)
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".", suffix=".tmp")
        os.close(fd)
        # -c: a clone on APFS, at once and without using space; elsewhere cp says so and the second one copies
        for args in (["/bin/cp", "-c", path, tmp], ["/bin/cp", path, tmp]):
            if subprocess.run(args, capture_output=True).returncode == 0:
                break
        else:
            raise Bad("Could not copy %s here." % name)
        os.replace(tmp, dest)
    except (Bad, OSError) as e:
        for f in filter(None, (tmp, dest)):
            try:
                os.unlink(f)
            except OSError:
                pass
        raise e if isinstance(e, Bad) else Bad("Could not copy %s here." % name)
    return dest


def plan(path, bottles, supported, only="", copy_for=0):
    """What ./revit open does. The rule that keeps a file from being upgraded unasked lives here: "open" only ever
    names a bottle of the file's own year, and "copy" happens only when copy_for is asked for."""
    r = info(path)
    shared = r["worksharing"] not in ("", "Not enabled")
    p = {"file": path, "format": r["format"], "worksharing": r["worksharing"], "error": r["error"], "size": r["size"],
         "mtime_ns": r["mtime_ns"], "action": "unreadable", "year": 0, "bottles": [], "newer": [], "can_add": False, "say": ""}
    y = r["format"]
    if y is None:
        p["say"] = "Cannot tell which Revit saved %s (%s)." % (os.path.basename(path), r["error"] or "it names no version")
        return p
    pool = [b for b in bottles if not only or b[1] == only]

    def rows(year):
        return sorted((b for b in pool if b[0] == year), key=lambda b: (not b[2], b[1]))

    for year in sorted({b[0] for b in pool if b[0] > y}):
        p["newer"].append({"year": year, "bottle": rows(year)[0][1]})
    p["can_add"] = y in supported
    if copy_for:
        ok = rows(copy_for)
        if copy_for <= y or not ok:
            p["action"], p["say"] = "refused", "A copy goes to a newer Revit that is on this Mac. This file is Revit %d." % y
        elif shared:
            p["action"], p["say"] = "refused", "This file uses worksharing. To upgrade it, open it in Revit %d with Detach from Central." % copy_for
        else:
            p["action"], p["year"] = "copy", copy_for
            p["bottles"] = [{"name": ok[0][1], "running": ok[0][2]}]
        return p
    same = rows(y)
    running = [b for b in same if b[2]]
    p["year"] = y
    use = running if running else same
    p["bottles"] = [{"name": b[1], "running": b[2]} for b in use]
    if len(use) == 1:
        p["action"] = "open"
    elif use:
        p["action"] = "pick_bottle"
        p["say"] = "Revit %d is in several bottles: %s. Add --bottle <bottle>." % (y, ", ".join(b[1] for b in use))
    else:
        p["action"] = "choose"
        options = ["./revit install %d" % y] if p["can_add"] else []
        options += ["./revit open <file> --copy-for %d" % n["year"] for n in p["newer"][:1] if not shared]
        p["say"] = "%s was saved in Revit %d, which is not on this Mac%s Nothing was opened.%s" % (
            os.path.basename(path), y, " (%s)." % only if only else ".",
            " You can run: " + " or ".join(options) if options else "")
    return p


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "info":
            r = info(argv[1])
            print(json.dumps(r))
            return 1 if r["error"] else 0
        if len(argv) == 3 and argv[0] == "winpath":
            print(winpath(argv[1], argv[2]))
            return 0
        if 3 <= len(argv) <= 5 and argv[0] == "plan":
            rows = [(int(a), b, c == "1") for a, b, c in (l.split() for l in sys.stdin if l.strip())]
            only, copy_for = (argv[3:] + ["", ""])[:2]
            print(json.dumps(plan(argv[1], rows, [int(y) for y in argv[2].split(",")], only, int(copy_for or 0))))
            return 0
        if len(argv) == 3 and argv[0] == "copy" and argv[2].isdigit():
            print(copy(argv[1], int(argv[2])))
            return 0
    except (Bad, OSError) as e:
        print(e, file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
