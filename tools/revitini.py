#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Set keys in Revit.ini (UTF-16 LE, CRLF, optional BOM), adding missing sections and keys at the end.

  revitini.py <Revit.ini> Section.Key=Value…

Edits the file in place and prints each change. Before the first edit the untouched file is kept as <Revit.ini>.orig.
Keys it does not name stay as they are, so running it again keeps what the user changed in Revit's Options since.
Run with python3 -I.
"""
import os
import shutil
import sys
import tempfile


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


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, pairs = sys.argv[1], sys.argv[2:]
    for p in pairs:
        if "=" not in p or "." not in p.split("=", 1)[0]:
            sys.exit(f"not Section.Key=Value: {p}")
    raw = open(path, "rb").read()
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    bom = raw.startswith(b"\xff\xfe")
    lines = raw.decode("utf-16").split("\r\n")
    for p in pairs:
        name, value = p.split("=", 1)
        section, key = name.split(".", 1)
        old = set_key(lines, section, key, value)
        print(f"[{section}] {old or '(none)'} -> {key}={value}")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, "wb") as f:
        f.write(("\ufeff" if bom else "").encode("utf-16-le") + "\r\n".join(lines).encode("utf-16-le"))
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
