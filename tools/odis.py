#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""ODIS distribution packages (manifest/app.*.xml -> pkg.*.xml) as lines for bash.

  odis.py list <dist>            all packages: name<TAB>installAs<TAB>type<TAB>file<TAB>installParams
  odis.py get  <dist> <name>...  same for the given names (in that order); a missing name is an error
file paths are relative to the distribution, with forward slashes. Run with python3 -I.
"""
import glob, html, os, re, sys

ATTR = re.compile(r'(\w+)="([^"]*)"')


def attrs(tag):
    return {k: html.unescape(v) for k, v in ATTR.findall(tag)}


def packages(dist):
    app = glob.glob(os.path.join(dist, "manifest", "app.*.xml"))
    if len(app) != 1:
        sys.exit(f"expected one manifest/app.*.xml in {dist}, found {len(app)}")
    for tag in re.findall(r"<Package\s[^>]*>", open(app[0], encoding="utf-8").read()):
        a = attrs(tag)
        pkg = open(os.path.join(dist, a["path"]), encoding="utf-8").read()
        f = re.search(r"<InstallFile\s[^>]*>", pkg)
        fa = attrs(f.group(0)) if f else {}
        yield a["name"], a.get("installAs", ""), fa.get("type", ""), fa.get("file", ""), fa.get("installParams", "")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("list", "get"):
        sys.exit(__doc__)
    cmd, dist, *names = sys.argv[1:]
    rows = list(packages(dist))
    if cmd == "get":
        by = {r[0]: r for r in rows}
        missing = [n for n in names if n not in by]
        if missing:
            sys.exit("no such packages: " + ", ".join(missing))
        rows = [by[n] for n in names]
    for r in rows:
        print("\t".join(r))


if __name__ == "__main__":
    main()
