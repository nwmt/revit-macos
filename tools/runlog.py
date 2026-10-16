#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The run record of a bottle: one JSON line per install, add-in or steps run in <bottle>/revit-macos/runs.ndjson.

  runlog.py append <bottle> --kind install|addins|steps --year Y --run-id ID --result ok|partial|failed|stopped
                   --requested "a b c" [--run-dir DIR] [--engine E] [--crossover V] [--compatdb FILE] [--shims S]
                   [--build B]
  runlog.py last <bottle> [--kind K]     the newest record (of that kind) as JSON; exit 1 when there is none

append takes done, skipped and failed from DIR/summary.txt, the lines "   <step> exit=<code> ..." of the requested
steps (0 done, skip skipped, anything else failed; a step's last line counts), and DIR/failed.txt. compatdb_sha256
is the sha256 of FILE, null without one. It writes only into a bottle that exists (cxbottle.conf) and never creates
one; the line goes out in one O_APPEND write. An error is one line on stderr and exit 1: the caller goes on.
scripts/lib/common.sh (runlog_append) calls it at the end of install.sh and of a run-steps.sh run of its own.
Run with python3 -I -B.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

KINDS = ("install", "addins", "steps")
RESULTS = ("ok", "partial", "failed", "stopped")
STEP_LINE = re.compile(r"^ {3}(\S+) +exit=(\S+)")


def runs_file(bottle):
    return os.path.join(bottle, "revit-macos", "runs.ndjson")


def _lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def steps_of(run_dir, requested):
    """(done, skipped, failed) of the requested steps, each in the order requested, from the run folder.
    failed.txt adds what it lists (install.sh and ./revit report the same list)."""
    code = {}
    for line in _lines(os.path.join(run_dir, "summary.txt")) if run_dir else []:
        m = STEP_LINE.match(line)
        if m and m.group(1) in requested:
            code[m.group(1)] = m.group(2)
    listed = [s.strip() for s in _lines(os.path.join(run_dir, "failed.txt")) if s.strip()] if run_dir else []
    done = [s for s in requested if code.get(s) == "0" and s not in listed]
    skipped = [s for s in requested if code.get(s) == "skip" and s not in listed]
    failed = [s for s in requested if (s in code and code[s] not in ("0", "skip")) or s in listed]
    failed += [s for i, s in enumerate(listed) if s not in requested and s not in listed[:i]]
    return done, skipped, failed


def sha256_of(path):
    if not path:
        return None
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def record(kind, year, run_id, result, requested, run_dir=None, engine=None, crossover=None, compatdb=None,
           shims=None, build=None):
    """One run record, its fields in the order of the file."""
    done, skipped, failed = steps_of(run_dir, requested)
    return {"run_id": run_id, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "kind": kind,
            "year": int(year), "requested": list(requested), "done": done, "skipped": skipped, "failed": failed,
            "result": result, "engine": engine or "unknown", "crossover": crossover or None,
            "compatdb_sha256": sha256_of(compatdb), "shims": shims or "unknown", "revit_build_expected": build or None}


def append(bottle, rec):
    """Adds the record as one line. Refuses a folder that is not a bottle: it never makes one."""
    if not os.path.isfile(os.path.join(bottle, "cxbottle.conf")):
        raise OSError(f"{bottle}: not a bottle (no cxbottle.conf)")
    path = runs_file(bottle)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = (json.dumps(rec, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        if os.write(fd, data) != len(data):
            raise OSError(f"{path}: short write")
    finally:
        os.close(fd)


def records(bottle):
    """Every record of the bottle, oldest first; a line that is not a JSON object is skipped."""
    out = []
    for line in _lines(runs_file(bottle)):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict):
            out.append(rec)
    return out


def last(bottle, kind=None):
    """The newest record (of that kind), or None."""
    for rec in reversed(records(bottle)):
        if kind is None or rec.get("kind") == kind:
            return rec
    return None


def main(argv):
    p = argparse.ArgumentParser(prog="runlog.py", description="The run record of a bottle.")
    sub = p.add_subparsers(dest="cmd")
    a = sub.add_parser("append")
    a.add_argument("bottle")
    a.add_argument("--kind", required=True, choices=KINDS)
    a.add_argument("--year", required=True, type=int)
    a.add_argument("--run-id", required=True)
    a.add_argument("--result", required=True, choices=RESULTS)
    a.add_argument("--requested", required=True)
    for opt in ("--run-dir", "--engine", "--crossover", "--compatdb", "--shims", "--build"):
        a.add_argument(opt, default="")
    la = sub.add_parser("last")
    la.add_argument("bottle")
    la.add_argument("--kind", choices=KINDS)
    o = p.parse_args(argv)
    if o.cmd == "append":
        rec = record(o.kind, o.year, o.run_id, o.result, o.requested.split(), o.run_dir, o.engine, o.crossover,
                     o.compatdb, o.shims, o.build)
        try:
            append(o.bottle, rec)
        except OSError as e:
            sys.stderr.write(f"{e.filename}: {e.strerror}\n" if e.filename and e.strerror else f"{e}\n")
            return 1
        return 0
    if o.cmd == "last":
        rec = last(o.bottle, o.kind)
        if rec is None:
            return 1
        print(json.dumps(rec, separators=(",", ":")))
        return 0
    p.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
