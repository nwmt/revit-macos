#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only parsers for the files of a CrossOver bottle and of a Revit install. Nothing here writes a file.

  bottleread.py conf <cxbottle.conf>            sections and keys as JSON
  bottleread.py ini <Revit.ini>                 sections and keys as JSON (UTF-16 with or without BOM)
  bottleread.py reg <system.reg|user.reg> <key>  the values of one registry key as JSON
  bottleread.py version <file.exe|dll>          the FileVersion of a PE file
  bottleread.py marker <file.dll>               the Wine marker in a PE header, if any

A library first: tools/doctor.py, tools/report.py and tools/smoke.py import it. Unlike bottle_env.py and
revitini.py, which always rewrite their file, these functions only read, so they are safe on a bottle that is in use.
Run with python3 -I -B.
"""
import json
import os
import re
import sys

CONF_LINE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*$')
MARKERS = (b"Wine builtin DLL", b"DXVK native  DLL", b"Wine orig    DLL")
FIXED_SIG = b"\xbd\x04\xef\xfe"   # VS_FIXEDFILEINFO.dwSignature 0xFEEF04BD, little endian
ESCAPES = {"\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t", "0": "\0", "a": "\a", "b": "\b", "e": "\x1b",
           "f": "\f", "v": "\v"}


def _unescape_conf(s):
    return re.sub(r"\\(.)", r"\1", s)


def read_conf(path):
    """cxbottle.conf → {section: {key: value}}. Keys and values are unescaped; lines that are not "Key" = "Value"
    are skipped. A missing file gives {}."""
    out, cur = {}, None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return {}
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            cur = out.setdefault(s[1:-1], {})
            continue
        m = CONF_LINE.match(line)
        if m and cur is not None:
            cur[_unescape_conf(m.group(1))] = _unescape_conf(m.group(2))
    return out


def _decode_ini(raw):
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    if len(raw) >= 2 and raw[1:2] == b"\0" and raw[0:1] != b"\0":   # UTF-16 LE without BOM
        return raw.decode("utf-16-le", errors="replace")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def read_ini(path):
    """Revit.ini (UTF-16 LE, CRLF, optional BOM) or any plain INI → {section: {key: value}}, as written in the
    file. Comment lines (;) and lines without '=' are skipped. A missing file gives {}."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return {}
    out, cur = {}, None
    for line in _decode_ini(raw).lstrip("﻿").splitlines():
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        if s.startswith("[") and s.endswith("]"):
            cur = out.setdefault(s[1:-1], {})
        elif "=" in s and cur is not None:
            k, v = s.split("=", 1)
            cur[k.strip()] = v.strip()
    return out


def ini_get(ini, section, key, default=None):
    """A value from read_ini's result, section and key compared without case."""
    for s, keys in ini.items():
        if s.lower() == section.lower():
            for k, v in keys.items():
                if k.lower() == key.lower():
                    return v
    return default


def _unescape_reg(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 == len(s):
            out.append(c)
            i += 1
            continue
        n = s[i + 1]
        if n == "x":
            m = re.match(r"[0-9a-fA-F]{1,4}", s[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
                continue
        if n in "01234567":   # control characters as \ooo; a lone \0 is NUL
            m = re.match(r"[0-7]{1,3}", s[i + 1:])
            out.append(chr(int(m.group(0), 8)))
            i += 1 + len(m.group(0))
            continue
        out.append(ESCAPES.get(n, n))
        i += 2
    return "".join(out)


def _split_quoted(s):
    """'"a\\"b"=rest' → ('a\\"b', 'rest'): the first quoted string (still escaped) and what follows its '='."""
    if not s.startswith('"'):
        return None, None
    i = 1
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == '"':
            break
        i += 1
    rest = s[i + 1:].lstrip()
    return s[1:i], rest[1:].lstrip() if rest.startswith("=") else None


def _hex_bytes(s):
    s = s.replace("\\", "").replace(" ", "").replace("\t", "")
    return bytes(int(x, 16) for x in s.split(",") if x)


def _reg_value(v):
    if v.startswith('"'):
        body, _ = _split_quoted(v + "=")
        return "sz", _unescape_reg(body or "")
    if v.startswith("dword:"):
        try:
            return "dword", int(v[6:].strip(), 16)
        except ValueError:
            return "dword", None
    m = re.match(r"str\((\d+)\):(.*)$", v)
    if m:
        body, _ = _split_quoted(m.group(2) + "=")
        text = _unescape_reg(body or "")
        if m.group(1) == "7":
            return "multi_sz", [p for p in text.split("\0") if p]
        return ("expand_sz" if m.group(1) == "2" else "str" + m.group(1)), text
    m = re.match(r"hex(?:\((\d+)\))?:(.*)$", v)
    if m:
        data = _hex_bytes(m.group(2))
        kind = m.group(1)
        if kind in ("2", "1", "7"):
            text = data.decode("utf-16-le", errors="replace").rstrip("\0")
            if kind == "7":
                return "multi_sz", [p for p in text.split("\0") if p]
            return ("expand_sz" if kind == "2" else "sz"), text
        return ("hex" if kind is None else "hex" + kind), data
    return "unknown", v


def read_reg(path):
    """A Wine registry file (system.reg, user.reg, userdef.reg) → {key: {name: (type, value)}}. Key paths have single
    backslashes and are lower case, relative to the file's root (HKLM for system.reg, HKCU for user.reg). Value
    names are lower case; '@' is the default value. Types: sz, expand_sz, multi_sz, dword, hex, hexN, strN."""
    out, cur = {}, None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    i = 0
    while i < len(lines):
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines) and not line.startswith("["):   # hex lists go on
            i += 1
            line = line[:-1] + lines[i].strip()
        i += 1
        if line.startswith("["):
            m = re.match(r"^\[((?:[^\]\\]|\\.)*)\]", line)
            if m:
                key = m.group(1).replace("\\\\", "\\").lower()
                cur = out.setdefault(key, {})
            continue
        if cur is None or not line or line[0] in ";#":
            continue
        if line.startswith("@="):
            cur["@"] = _reg_value(line[2:].strip())
            continue
        name, rest = _split_quoted(line)
        if name is not None and rest is not None:
            cur[_unescape_reg(name).lower()] = _reg_value(rest)
    return out


def reg_get(reg, key, name="@"):
    """(type, value) of one value from read_reg's result, or None. key: with single backslashes, any case."""
    vals = reg.get(key.replace("/", "\\").lower())
    if vals is None:
        return None
    return vals.get(name.lower())


def pe_marker(path):
    """The 16-byte Wine marker in a PE header (first 0x100 bytes): b'Wine builtin DLL' for Wine's own DLLs, the
    markers tools/pe_mark.py writes for our copies, or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(0x100)
    except OSError:
        return None
    for m in MARKERS:
        if m in head:
            return m
    return None


def pe_file_version(path, limit=256 * 1024 * 1024):
    """FileVersion "a.b.c.d" from the PE's VS_FIXEDFILEINFO (found by its signature), or None."""
    try:
        f = open(path, "rb")
    except OSError:
        return None
    with f:
        if f.read(2) != b"MZ":
            return None
        f.seek(0)
        tail, done = b"", 0
        while done < limit:
            chunk = f.read(1 << 20)
            if not chunk:
                return None
            buf = tail + chunk
            start = 0
            while True:
                j = buf.find(FIXED_SIG, start)
                if j < 0 or j + 16 > len(buf):
                    break
                struc = int.from_bytes(buf[j + 4:j + 8], "little")
                if struc == 0x00010000:
                    ms = int.from_bytes(buf[j + 8:j + 12], "little")
                    ls = int.from_bytes(buf[j + 12:j + 16], "little")
                    return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
                start = j + 1
            tail = buf[-15:]
            done += len(chunk)
    return None


def journals_dir(bottle, year):
    return os.path.join(bottle, "drive_c", "users", "crossover", "AppData", "Local", "Autodesk", "Revit",
                        f"Autodesk Revit {year}", "Journals")


def newest_journal(bottle, year):
    """The newest journal.NNNN.txt Revit wrote in the bottle (by modification time), or None."""
    d = journals_dir(bottle, year)
    try:
        names = [n for n in os.listdir(d) if re.match(r"^journal\.\d+\.txt$", n)]
    except OSError:
        return None
    paths = [os.path.join(d, n) for n in names]
    return max(paths, key=lambda p: (os.path.getmtime(p), p)) if paths else None


def read_lines(path, max_bytes=None, max_line=4000, start=0):
    """Lines of a text file that may be huge, binary in places or still growing: decoded with errors='replace', read
    up to the size the file had when opened (or max_bytes), each line cut to max_line characters. start: a byte offset
    to begin at; the line it falls in is skipped, so the first line given is the next whole one."""
    try:
        f = open(path, "rb")
    except OSError:
        return
    with f:
        size = os.fstat(f.fileno()).st_size
        if max_bytes is not None:
            size = min(size, max_bytes)
        left = size
        if start > 0:
            f.seek(start - 1)   # from the byte before: when it ends a line, nothing of the next one is lost
            left = size - start + 1
            while left > 0:
                raw = f.readline(min(left, 1 << 16))
                if not raw:
                    break
                left -= len(raw)
                if raw.endswith(b"\n"):
                    break
        while left > 0:
            raw = f.readline(min(left, 1 << 16))
            if not raw:
                break
            left -= len(raw)
            keep = raw
            while not raw.endswith(b"\n") and left > 0:   # a very long line: read on to its end, keep the start
                raw = f.readline(min(left, 1 << 16))
                if not raw:
                    break
                left -= len(raw)
                if len(keep) < max_line * 4:
                    keep += raw
            yield keep.decode("utf-8", errors="replace").rstrip("\r\n")[:max_line]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "conf":
        print(json.dumps(read_conf(path), indent=1))
    elif cmd == "ini":
        print(json.dumps(read_ini(path), indent=1, ensure_ascii=False))
    elif cmd == "reg" and len(sys.argv) == 4:
        vals = read_reg(path).get(sys.argv[3].lower())
        if vals is None:
            sys.exit(1)
        print(json.dumps({k: [t, v if not isinstance(v, bytes) else v.hex()] for k, (t, v) in vals.items()}, indent=1))
    elif cmd == "version":
        v = pe_file_version(path)
        if not v:
            sys.exit(1)
        print(v)
    elif cmd == "marker":
        m = pe_marker(path)
        if not m:
            sys.exit(1)
        print(m.decode("ascii"))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
