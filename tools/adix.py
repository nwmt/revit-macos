#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Autodesk ADIX packages (Revit 2026+): essentially MSIX -- a zip with VFS/<folder>/..., Registry.dat (regf hive), AppxManifest.xml.
ODIS deploys them "flat": files into known folders, registry into the regular registry. We do the same for a Wine bottle.

  adix.py files <package.adix> <drive_c>      extract VFS into the bottle's drive_c (prints the file count)
  adix.py reg   <package.adix> <out.reg>      Registry.dat -> .reg (UTF-16, for `wine regedit /s`); no hive, no file
  adix.py dump  <package.adix>                print the Registry.dat tree
Run with python3 -I (the distribution is untrusted data).
"""
import os, struct, sys, zipfile
from urllib.parse import unquote

# Known MSIX VFS folders -> bottle paths (drive_c). The 2026 distribution uses only six of them.
VFS = {
    "ProgramFilesX64": "Program Files",
    "ProgramFilesX86": "Program Files (x86)",
    "ProgramFilesCommonX64": "Program Files/Common Files",
    "ProgramFilesCommonX86": "Program Files (x86)/Common Files",
    "Common AppData": "ProgramData",
    "Fonts": "windows/Fonts",
    "SystemX64": "windows/system32",
    "SystemX86": "windows/syswow64",
    "Windows": "windows",
}
# The same folders as tokens in MSIX registry values ([{ProgramFilesX64}]\...)
TOKENS = {f"[{{{k}}}]": "C:\\" + v.replace("/", "\\") for k, v in VFS.items()}


def files(adix, drive_c):
    n = 0
    with zipfile.ZipFile(adix) as z:
        for info in z.infolist():
            name = unquote(info.filename)
            if not name.startswith("VFS/") or name.endswith("/"):
                continue
            _, root, rest = name.split("/", 2)
            if root not in VFS:
                sys.exit(f"unknown VFS folder: {root} ({name})")
            dst = os.path.join(drive_c, VFS[root], *rest.split("/"))
            if ".." in rest.split("/") or "\\" in rest:
                sys.exit(f"suspicious path: {name}")
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with z.open(info) as src, open(dst, "wb") as out:
                while chunk := src.read(1 << 20):
                    out.write(chunk)
            n += 1
    print(n)


class Hive:
    """Minimal regf parser: nk keys, vk values, lf/lh/li/ri lists, db big data."""

    def __init__(self, data):
        assert data[:4] == b"regf", "not regf"
        self.d = data
        self.root = struct.unpack_from("<I", data, 0x24)[0]

    def cell(self, off):
        p = 0x1000 + off
        size = -struct.unpack_from("<i", self.d, p)[0]
        return self.d[p + 4 : p + size]

    def key(self, off):
        c = self.cell(off)
        assert c[:2] == b"nk", c[:2]
        flags, = struct.unpack_from("<H", c, 2)
        nsub, = struct.unpack_from("<I", c, 0x14)
        lsub, = struct.unpack_from("<I", c, 0x1C)
        nval, lval = struct.unpack_from("<II", c, 0x24)
        nlen, = struct.unpack_from("<H", c, 0x48)
        raw = c[0x4C : 0x4C + nlen]
        name = raw.decode("latin-1") if flags & 0x20 else raw.decode("utf-16le")
        return name, (self.subkeys(lsub) if nsub else []), (self.values(lval, nval) if nval else [])

    def subkeys(self, off):
        c = self.cell(off)
        sig, n = c[:2], struct.unpack_from("<H", c, 2)[0]
        if sig in (b"lf", b"lh"):
            return [struct.unpack_from("<I", c, 4 + 8 * i)[0] for i in range(n)]
        if sig == b"li":
            return [struct.unpack_from("<I", c, 4 + 4 * i)[0] for i in range(n)]
        if sig == b"ri":
            return [k for i in range(n) for k in self.subkeys(struct.unpack_from("<I", c, 4 + 4 * i)[0])]
        raise ValueError(sig)

    def values(self, off, n):
        lst = self.cell(off)
        out = []
        for i in range(n):
            c = self.cell(struct.unpack_from("<I", lst, 4 * i)[0])
            assert c[:2] == b"vk"
            nlen, size, doff, typ, flags = struct.unpack_from("<HIIIH", c, 2)
            raw = c[20 : 20 + nlen]
            name = raw.decode("latin-1") if flags & 1 else raw.decode("utf-16le")
            if size & 0x80000000:  # data stored inline in the offset field
                data = struct.pack("<I", doff)[: size & 0x7FFFFFFF]
            else:
                d = self.cell(doff)
                if d[:2] == b"db" and size > 16344:
                    cnt, segs = struct.unpack_from("<HI", d, 2)
                    sl = self.cell(segs)
                    d = b"".join(self.cell(struct.unpack_from("<I", sl, 4 * j)[0])[:16344] for j in range(cnt))
                data = d[:size]
            out.append((name, typ, data))
        return out

    def walk(self, off=None, path=()):
        name, subs, vals = self.key(self.root if off is None else off)
        p = path + (name,) if off is not None else ()
        yield p, vals
        for s in subs:
            yield from self.walk(s, p)


def hive_of(adix):
    with zipfile.ZipFile(adix) as z:
        if "Registry.dat" not in z.namelist():
            return None
        return Hive(z.read("Registry.dat"))


def win_key(path):
    """REGISTRY\\MACHINE\\... -> HKEY_LOCAL_MACHINE\\...; REGISTRY\\USER\\[{AppVCurrentUserSID}]\\... -> HKEY_CURRENT_USER\\..."""
    if len(path) >= 2 and path[0].upper() == "REGISTRY" and path[1].upper() == "MACHINE":
        return "\\".join(("HKEY_LOCAL_MACHINE",) + path[2:])
    if len(path) >= 3 and path[0].upper() == "REGISTRY" and path[1].upper() == "USER":
        return "\\".join(("HKEY_CURRENT_USER",) + path[3:])
    return None


def expand(s):
    for t, v in TOKENS.items():
        s = s.replace(t, v)
    return s


def reg_value(name, typ, data):
    q = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    left = "@" if name == "" else f'"{q(name)}"'
    if typ == 1:  # REG_SZ
        return f'{left}="{q(expand(data.decode("utf-16le").rstrip(chr(0))))}"'
    if typ == 4 and len(data) == 4:
        return f"{left}=dword:{struct.unpack('<I', data)[0]:08x}"
    if typ in (2, 7):  # EXPAND_SZ, MULTI_SZ: expand tokens in the text
        data = expand(data.decode("utf-16le")).encode("utf-16le")
    return f"{left}=hex({typ:x}):" + ",".join(f"{b:02x}" for b in data)


def reg(adix, out):
    h = hive_of(adix)
    if h is None:
        return
    lines, skipped, nkeys = ["Windows Registry Editor Version 5.00", ""], 0, 0
    for path, vals in h.walk():
        k = win_key(path)
        if k is None or k in ("HKEY_LOCAL_MACHINE", "HKEY_CURRENT_USER"):
            skipped += len(vals)
            continue
        if not vals:
            continue
        nkeys += 1
        lines.append(f"[{k}]")
        lines += [reg_value(*v) for v in vals]
        lines.append("")
    with open(out, "w", encoding="utf-16") as f:
        f.write("\r\n".join(lines) + "\r\n")
    print(f"{nkeys} keys" + (f", skipped values outside MACHINE/USER: {skipped}" if skipped else ""))


def dump(adix):
    h = hive_of(adix)
    if h is None:
        print("no Registry.dat")
        return
    for path, vals in h.walk():
        print("\\".join(path) or "<root>")
        for name, typ, data in vals:
            print("   ", reg_value(name, typ, data)[:200])


if __name__ == "__main__":
    cmd, *args = sys.argv[1:]
    {"files": files, "reg": reg, "dump": dump}[cmd](*args)
