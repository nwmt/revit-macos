#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read a Windows shortcut (.lnk) and turn a Windows icon (.ico) into a macOS .icns.

  win_shortcut.py info <file.lnk>          prints target, arguments and icon path, tab-separated
  win_shortcut.py icns <file.ico> <out.icns>

Why: the installers create Start Menu shortcuts with the right command line for each Revit version
(e.g. "/viewer /language ENU", or "/language en-US" in 2027) and point to the product icons.
The macOS launchers reuse both instead of hardcoding them per year.
Format: [MS-SHLLINK] (header, optional ID list and LinkInfo, then counted StringData).
"""
import os
import struct
import subprocess
import sys
import tempfile

HAS_IDLIST, HAS_LINKINFO, HAS_NAME, HAS_RELPATH, HAS_WORKDIR, HAS_ARGS, HAS_ICON, UNICODE = (
    1, 2, 4, 8, 0x10, 0x20, 0x40, 0x80)


def lnk_info(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x4c\x00\x00\x00":
        sys.exit(f"not a shortcut: {path}")
    flags = struct.unpack_from("<I", d, 20)[0]
    pos, target = 76, ""
    if flags & HAS_IDLIST:
        pos += 2 + struct.unpack_from("<H", d, pos)[0]
    if flags & HAS_LINKINFO:
        size, hdr, _, _, base_off, _, suffix_off = struct.unpack_from("<7I", d, pos)

        def cstr(o):
            return d[pos + o:d.index(b"\0", pos + o)].decode("mbcs" if os.name == "nt" else "latin-1")
        target = cstr(base_off) + (cstr(suffix_off) if suffix_off else "")
        pos += size
    strings = {}
    for flag in (HAS_NAME, HAS_RELPATH, HAS_WORKDIR, HAS_ARGS, HAS_ICON):
        if flags & flag:
            n = struct.unpack_from("<H", d, pos)[0]
            pos += 2
            width = 2 if flags & UNICODE else 1
            raw = d[pos:pos + n * width]
            strings[flag] = raw.decode("utf-16-le" if width == 2 else "latin-1").strip("\0 ")
            pos += n * width
    return target, strings.get(HAS_ARGS, ""), strings.get(HAS_ICON, "")


def ico_to_icns(ico, out):
    d = open(ico, "rb").read()
    count = struct.unpack_from("<H", d, 4)[0]
    best = max((struct.unpack_from("<BBBBHHII", d, 6 + 16 * i) for i in range(count)),
               key=lambda e: ((e[0] or 256), e[5]))
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "icon.png")
        size, off = best[6], best[7]
        if d[off:off + 4] == b"\x89PNG":  # Vista-style 256 px entry: already a PNG
            open(png, "wb").write(d[off:off + size])
        else:  # let macOS pick and decode the BMP entries
            subprocess.run(["sips", "-s", "format", "png", ico, "--out", png], check=True, capture_output=True)
        iconset = os.path.join(tmp, "icon.iconset")
        os.mkdir(iconset)
        for px in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                subprocess.run(["sips", "-z", str(px * scale), str(px * scale), png,
                                "--out", os.path.join(iconset, f"icon_{px}x{px}{suffix}.png")],
                               check=True, capture_output=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "info":
        print("\t".join(lnk_info(sys.argv[2])))
    elif len(sys.argv) == 4 and sys.argv[1] == "icns":
        ico_to_icns(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
