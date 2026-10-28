# SPDX-License-Identifier: MIT
"""The pinned Python packages of the MCP server for Revit (Python), for `pip install --require-hashes`.

Reads the project's uv.lock, follows its root package's dependencies (with extras) and keeps what the lock's markers
select for the one interpreter we install them into: python-build-standalone 3.14.8 on macOS arm64 (app/tools.sh).
Prints one line per package, sorted: `name==version --hash=sha256:<sdist> --hash=sha256:<wheel>…` (every file hash
the lock lists; pip takes the one it downloads).

Usage (Python 3.11 or newer, for tomllib): python3 -I tools/gen_python_mcp_requirements.py <uv.lock>  > tools/python-mcp-requirements.txt
"""
import re
import sys
import tomllib

ENV = {"python_full_version": "3.14.8", "python_version": "3.14", "sys_platform": "darwin",
       "platform_system": "Darwin", "platform_machine": "arm64", "implementation_name": "cpython",
       "platform_python_implementation": "CPython", "os_name": "posix"}
VERSIONED = {"python_full_version", "python_version"}
TOKEN = re.compile(r"\s*(?:(\()|(\))|(and|or)\b|(\w+)\s*(==|!=|<=|>=|<|>)\s*'([^']*)')")


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def compare(name, op, value):
    left, right = (vtuple(ENV[name]), vtuple(value)) if name in VERSIONED else (ENV.get(name, ""), value)
    return {"==": left == right, "!=": left != right, "<": left < right, "<=": left <= right,
            ">": left > right, ">=": left >= right}[op]


def marker_true(marker, extras=()):
    """A PEP 508 marker as uv writes them: comparisons joined by and/or, with parentheses."""
    toks, pos = [], 0
    while pos < len(marker):
        m = TOKEN.match(marker, pos)
        if not m:
            raise ValueError("cannot read marker: %r" % marker)
        pos = m.end()
        if m.group(4):
            name, op, value = m.group(4), m.group(5), m.group(6)
            toks.append(str(value in extras if name == "extra" else compare(name, op, value)))
        else:
            toks.append(m.group(1) or m.group(2) or m.group(3))
    return eval(" ".join(toks), {"__builtins__": {}})   # only True/False/and/or/parentheses


def requirements(lock):
    pkgs = {p["name"]: p for p in lock["package"]}
    root = [p for p in lock["package"] if p.get("source", {}).get("virtual") == "."][0]
    seen, todo = set(), list(root.get("dependencies", []))
    while todo:
        dep = todo.pop()
        if "marker" in dep and not marker_true(dep["marker"]):
            continue
        p = pkgs[dep["name"]]
        for part in [None] + list(dep.get("extra", [])):   # the package itself, then each extra it is asked with
            if (p["name"], part) in seen:
                continue
            seen.add((p["name"], part))
            todo.extend(p.get("dependencies", []) if part is None else p.get("optional-dependencies", {}).get(part, []))
    out = []
    for name in sorted({n for n, _ in seen}):
        p = pkgs[name]
        hashes = ([p["sdist"]["hash"]] if "sdist" in p else []) + [w["hash"] for w in p.get("wheels", [])]
        out.append("%s==%s %s" % (name, p["version"], " ".join("--hash=" + h for h in hashes)))
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        print("\n".join(requirements(tomllib.load(f))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
