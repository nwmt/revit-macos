#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Environment variables for every process in a CrossOver bottle: the [EnvironmentVariables] section of cxbottle.conf.

  bottle_env.py <cxbottle.conf> KEY=VALUE…   set
  bottle_env.py <cxbottle.conf> -KEY…        remove
  bottle_env.py <cxbottle.conf>              show

Needed for processes our commands do not start (AdSSO starts the licensing agent). Prints the section afterwards.
A missing section is added. Values are quoted and escaped as CrossOver reads them. Run with python3 -I.
"""
import os
import re
import sys
import tempfile

SECTION = "[EnvironmentVariables]"
KEY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=')


def unescape(s):
    return re.sub(r"\\(.)", r"\1", s)


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    conf, args = sys.argv[1], sys.argv[2:]
    if not os.path.isfile(conf):
        sys.exit(f"no {conf}")
    lines = open(conf, encoding="utf-8").read().split("\n")
    if SECTION not in (l.strip() for l in lines):
        while lines and lines[-1] == "":
            lines.pop()
        lines += [SECTION, ""]
    start = next(i for i, l in enumerate(lines) if l.strip() == SECTION)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    for a in args:
        if a.startswith("-"):
            key, value = a[1:], None
        elif "=" in a:
            key, value = a.split("=", 1)
        else:
            sys.exit(f"not KEY=VALUE or -KEY: {a}")
        at = next((i for i in range(start + 1, end) if (m := KEY.match(lines[i])) and unescape(m.group(1)) == key), None)
        line = f'"{escape(key)}" = "{escape(value)}"' if value is not None else None
        if at is not None and line is None:
            del lines[at]
            end -= 1
        elif at is not None:
            lines[at] = line
        elif line is not None:
            lines.insert(start + 1, line)
            end += 1
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(conf)))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, conf)
    for i in range(start, end):
        if KEY.match(lines[i]) or lines[i].startswith("["):
            print(lines[i])


if __name__ == "__main__":
    main()
