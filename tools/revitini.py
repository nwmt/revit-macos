#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Set keys in Revit.ini (UTF-16 LE, CRLF, optional BOM), adding missing sections and keys at the end.

  revitini.py <src> <out> Section.Key=Value...
Reads <src> (keep an untouched copy there, so re-running gives the same result), writes <out>, prints each change.
Run with python3 -I.
"""
import sys


def set_key(lines, section, key, value):
    head = f"[{section}]"
    if head not in lines:
        while lines and lines[-1] == "":
            lines.pop()
        lines += [head, f"{key}={value}", ""]
        return None
    i = lines.index(head) + 1
    while i < len(lines) and not lines[i].startswith("["):
        if lines[i].split("=", 1)[0] == key:
            old, lines[i] = lines[i], f"{key}={value}"
            return old
        i += 1
    while i > 0 and lines[i - 1] == "":  # keep a blank line before the next section where there was one
        i -= 1
    lines.insert(i, f"{key}={value}")
    return None


if __name__ == "__main__":
    src, out, *pairs = sys.argv[1:]
    raw = open(src, "rb").read()
    bom = raw.startswith(b"\xff\xfe")
    lines = raw.decode("utf-16").split("\r\n")
    for p in pairs:
        name, value = p.split("=", 1)
        section, key = name.split(".", 1)
        old = set_key(lines, section, key, value)
        print(f"[{section}] {old or '(none)'} -> {key}={value}")
    open(out, "wb").write(("﻿" if bom else "").encode("utf-16-le") + "\r\n".join(lines).encode("utf-16-le"))
