#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rewrite the "Wine builtin DLL" marker of a PE file, so Wine loads the copy as a native DLL.

  pe_mark.py <in.dll> <out.dll> <new marker, 16 characters>

Wine's loader swaps a DLL that carries the marker (in the first 0x100 bytes) for its own builtin one. The DXVK d3d9.dll
in CrossOver and Wine's own version.dll carry it; their copies for Revit and WebView2 must not.
Run with python3 -I.
"""
import sys

MARK = b"Wine builtin DLL"


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, out, new = sys.argv[1], sys.argv[2], sys.argv[3].encode("ascii")
    if len(new) != len(MARK):
        sys.exit(f"the new marker must be {len(MARK)} characters: {sys.argv[3]!r}")
    data = bytearray(open(src, "rb").read())
    i = data.find(MARK)
    if not 0 < i < 0x100:
        sys.exit(f"{src}: no Wine builtin marker in its header")
    data[i:i + len(MARK)] = new
    with open(out, "wb") as f:
        f.write(data)


if __name__ == "__main__":
    main()
