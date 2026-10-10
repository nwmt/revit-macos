#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Unpack an Autodesk multi-part download (*_001_NNN.sfx.exe … *_NNN_NNN.sfx.exe) without running it.

Why: the self-extractor is a 32-bit Windows program and runs out of memory under Wine.
Format (Revit 2020, as observed): each part is a PE stub plus an overlay. The overlay starts with
MAGIC and a header of 64-bit fields written as 16 hex digits:
  header size, part number, part count, payload bytes in this part, a size field (not the unpacked size),
  payload offset in the file, overlay offset in the file
followed by the file name, the download name and a GUID. The payloads of all parts, in order,
are one raw LZMA2 stream (part 1 starts with a 0x1e marker byte) that ends with the LZMA2 end marker.
Unpacked, it is one tar archive.

Usage: adsk_sfx.py <first part> <destination folder>
"""
import lzma
import os
import re
import subprocess
import sys

MAGIC = b"\x1d\x1d\x1e|*\x02\x1e\x1d"
CHUNK = 16 << 20
DICT = 1 << 29  # raw LZMA2 needs a dictionary at least as large as the encoder's


def header(f):
    f.seek(0)
    buf = f.read(64 << 20)
    i = buf.find(MAGIC)
    if i < 0:
        sys.exit(f"not an Autodesk multi-part archive: {f.name}")
    raw = buf[i + len(MAGIC):i + len(MAGIC) + 16 * 7].decode("ascii")
    _, part, parts, size, _, data_off, _ = (int(raw[k:k + 16], 16) for k in range(0, 112, 16))
    return part, parts, size, data_off


def parts_of(first):
    m = re.match(r"(.*_)001_(\d{3})(\.sfx\.exe)$", first, re.I)
    if not m:
        sys.exit(f"expected the first part (*_001_NNN.sfx.exe): {first}")
    paths = [f"{m.group(1)}{n:03d}_{m.group(2)}{m.group(3)}" for n in range(1, int(m.group(2)) + 1)]
    missing = [p for p in paths if not os.path.isfile(p)]
    if missing:
        sys.exit("missing parts:\n  " + "\n  ".join(missing))
    return paths


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    paths, dest = parts_of(sys.argv[1]), sys.argv[2]
    os.makedirs(dest, exist_ok=True)
    tar = subprocess.Popen(["tar", "-x", "-f", "-", "-C", dest], stdin=subprocess.PIPE)
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{"id": lzma.FILTER_LZMA2, "dict_size": DICT}])
    out = 0
    for n, path in enumerate(paths, 1):
        with open(path, "rb") as f:
            part, parts, left, data_off = header(f)
            if (part, parts) != (n, len(paths)):
                sys.exit(f"{path}: header says part {part} of {parts}, expected {n} of {len(paths)}")
            f.seek(data_off)
            if n == 1:
                if f.read(1) != b"\x1e":
                    sys.exit(f"{path}: unexpected start of data")
                left -= 1
            while left > 0:
                data = f.read(min(CHUNK, left))
                if not data:
                    sys.exit(f"{path}: file is shorter than its header says (incomplete download?)")
                left -= len(data)
                block = dec.decompress(data)
                tar.stdin.write(block)
                out += len(block)
        print(f"part {n}/{len(paths)} done, {out / 1e9:.1f} GB unpacked", flush=True)
    tar.stdin.close()
    if not dec.eof:
        sys.exit(f"archive incomplete: no end marker after {out} bytes (corrupt or missing part?)")
    if tar.wait() != 0:
        sys.exit("tar failed")
    print(f"done: {dest}")


if __name__ == "__main__":
    main()
