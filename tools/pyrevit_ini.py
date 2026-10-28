# SPDX-License-Identifier: MIT
"""One key of pyRevit's pyRevit_config.ini, the rest of the file byte for byte.

  pyrevit_ini.py set <ini> <section> <key> <value>   replace the key (section and key in any case; more than one
                                                      becomes one) or add it at the end of its section; a missing
                                                      section is added at the end
  pyrevit_ini.py get <ini> <section> <key>            print the value (the last one, as pyRevit reads it); exit 1
                                                      when there is none
Values are written as given: pyRevit quotes strings itself (host = "127.0.0.1"), booleans and numbers are bare.
Line ends stay as the file has them (pyRevit writes LF; a file from Windows may have CRLF). Exit 1: no such file.
"""
import re
import sys

SECTION = re.compile(r"^\s*\[(.+?)\]\s*$")
KEY = re.compile(r"^\s*([^=\s][^=]*?)\s*=(.*)$")


def find(lines, section, key):
    """(index of the section header or None, indexes of the key's lines, index after the section's last line)."""
    head, at = None, []
    end = len(lines)
    for i, line in enumerate(lines):
        s = SECTION.match(line.rstrip("\r\n"))
        if s:
            if head is not None:
                end = i
                break
            if s.group(1).strip().lower() == section.lower():
                head = i
            continue
        if head is not None:
            k = KEY.match(line.rstrip("\r\n"))
            if k and k.group(1).strip().lower() == key.lower():
                at.append(i)
    return head, at, end


def main(argv):
    if len(argv) < 5 or argv[1] not in ("set", "get") or (argv[1] == "set") != (len(argv) == 6):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, section, key = argv[2], argv[3], argv[4]
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except OSError:
        return 1
    nl = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    head, at, end = find(lines, section, key)
    if argv[1] == "get":
        if not at:
            return 1
        print(KEY.match(lines[at[-1]].rstrip("\r\n")).group(2).strip())
        return 0
    new = "%s = %s%s" % (key, argv[5], nl)
    if at:
        lines[at[0]] = new
        for i in reversed(at[1:]):   # pyRevit would take the last one
            del lines[i]
    elif head is not None:
        while end > head + 1 and not lines[end - 1].strip():   # after the section's last line, before blank lines
            end -= 1
        lines.insert(end, new)
    else:
        if lines and not lines[-1].endswith(("\n", "\r")):
            lines[-1] += nl
        lines += ([nl] if lines else []) + ["[%s]%s" % (section, nl), new]
    with open(path, "wb") as f:
        f.write("".join(lines).encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
