# SPDX-License-Identifier: MIT
"""The states of a command sent to Revit, for tools/ui_server.py.

WM_COMMAND gives no answer, so the journal is the proof: a line with the label Internal and the command's ID. No line
does not mean no command: it may be waiting in Revit's queue. Commands run in the order they were sent, so a barrier, a
command that always leaves a line, proves that everything sent before it was handled: X with no line before the
barrier did not run. There is no command that leaves no trace, so the barrier is a toggle, and parity() sends one more
when an odd number came through.

  sent, seen   barriers posted (or their answer lost), barrier lines read; sent - seen may still be in the queue
  need         at the time X went: that many barrier lines after X prove it, one for each older barrier + one of its own

A lost answer only makes need too big: a later barrier makes up for it, never a false not_run. All of it lives in
<bottle>/revit-macos/ui.json, under ui.lock, so a second client, another copy of this project, a reconnect and a crash
see the same thing. The record goes to disk before the message goes out. A new Revit starts it afresh.
"""
import contextlib
import fcntl
import json
import os

QUIET_S = 20          # no new lines this long: parity() may send
BARRIER_WAIT_S = 20
POLL_S = 0.25
DIALOG_WAIT_S = 1.5   # the journal line comes before the command's dialog is up
UIA_WAIT_S = 120
INTERNAL = "Internal"


def blank(generation):
    return {"generation": generation, "journal": {"offset": 0, "identity": None}, "sent": 0, "seen": 0, "pending": None,
            "last": None, "last_record": 0, "uia": {"owner": None, "until": 0, "wait": UIA_WAIT_S}}


class State:
    def __init__(self, bottle, generation):
        self.dir = os.path.join(bottle, "revit-macos")
        self.path, self.lock = os.path.join(self.dir, "ui.json"), os.path.join(self.dir, "ui.lock")
        self.generation = generation

    @contextlib.contextmanager
    def locked(self):
        os.makedirs(self.dir, exist_ok=True)
        fd = os.open(self.lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            return blank(self.generation)
        return d if isinstance(d, dict) and d.get("generation") == self.generation else blank(self.generation)

    def save(self, d):
        tmp = self.path + ".new"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)


class Runner:
    """bridge: state(), command(n) -> posted|blocked|failed|lost, pid_start(), alive(pid, start), terminate_old(pid, start).
    reader_for(offset, identity): .read() -> [Rec], .offset, .identity, .lost. table: .number(id), or None."""

    def __init__(self, state, bridge, reader_for, table, now, sleep, barrier):
        self.st, self.b, self.reader_for, self.table = state, bridge, reader_for, table
        self.now, self.sleep, self.barrier = now, sleep, barrier
        self.activity = []

    def _sync(self, d):
        """New lines into d. False: the journal is gone, nothing can be proved any more."""
        r = self.reader_for(d["journal"]["offset"], d["journal"]["identity"])
        recs = r.read()
        if r.lost:
            return False
        d["journal"] = {"offset": r.offset, "identity": list(r.identity) if r.identity else None}
        for rec in recs:
            d["last_record"] = self.now()
            p = d["pending"]
            if rec.label == INTERNAL and rec.command == self.barrier:
                d["seen"] += 1
                if p:
                    p["after"] += 1
                    if p["after"] >= p["need"]:
                        d["last"], d["pending"] = {"id": p["id"], "status": "not_run"}, None
            elif p and rec.label == INTERNAL and rec.command == p["id"]:
                d["last"], d["pending"] = {"id": p["id"], "status": "ran"}, None
            else:
                self.activity.append("%s %s" % (rec.label, rec.command))
        return True

    def _wait(self, d, seconds):
        """Until the pending command is settled or the time is up. False: the journal is gone."""
        end = self.now() + seconds
        while d["pending"] and self.now() < end:
            self.sleep(POLL_S)
            if not self._sync(d):
                self.st.save(d)
                return False
            self.st.save(d)
        return True

    @staticmethod
    def _usable(s):
        return bool(s["main"] and s["enabled"] and s["responds"])

    def _fence(self, d):
        """The bridge that took the pending command must be gone or be ours: it could still post it after a not_run."""
        p = d["pending"]
        old = p.get("bridge")
        if not old or tuple(old) == tuple(self.b.pid_start()) or not self.b.alive(*old):
            return True
        if not self.b.terminate_old(*old):
            return False
        p["bridge"] = list(self.b.pid_start())
        self.st.save(d)
        return True

    def _send_barrier(self, d):
        n = self.table.number(self.barrier) if self.table else None
        if n is None or not self._usable(self.b.state()):
            return False
        d["sent"] += 1
        self.st.save(d)
        if self.b.command(n) in ("blocked", "failed"):
            d["sent"] -= 1
            self.st.save(d)
            return False
        return True

    def _settle(self, d):
        """One barrier for the pending command, and the wait for it. False: the journal is gone."""
        if d["pending"] and self._fence(d) and self._send_barrier(d):
            return self._wait(d, BARRIER_WAIT_S)
        return True

    def _answer(self, status, cid, previous=None, before=()):
        s = self.b.state()
        new = [x for x in s["dialogs"] if x["hwnd"] not in before]
        end = self.now() + DIALOG_WAIT_S
        while status == "ran" and not new and s["enabled"] and self.now() < end:
            self.sleep(POLL_S)
            s = self.b.state()
            new = [x for x in s["dialogs"] if x["hwnd"] not in before]
        # one dialog is the command's; two new ones, the lower greyed, is a command that went over a dialog just opened
        got = {"status": status, "id": cid, "dialogs": s["dialogs"],
               "overlapped": len(new) > 1 and any(not x["enabled"] for x in new), "other_activity": self.activity}
        if previous:
            got["previous"] = previous
        return got

    def run(self, cid, wait_s):
        self.activity = []
        n = self.table.number(cid) if self.table else None
        if cid == self.barrier or n is None:
            return {"status": "refused", "id": cid}
        with self.st.locked():
            d = self.st.load()
            had = d["pending"]
            if not self._sync(d):
                self.st.save(d)
                return self._answer("no_journal", cid)
            if d["pending"] and not self._settle(d):
                return self._answer("no_journal", cid)
            if d["pending"]:
                self.st.save(d)
                got = self._answer("pending", cid)
                got["pending_command"] = d["pending"]["id"]
                return got
            previous = d["last"] if had else None
            d["last"] = None
            s = self.b.state()
            if not self._usable(s):
                self.st.save(d)
                return self._answer("blocked", cid, previous)
            before = [x["hwnd"] for x in s["dialogs"]]
            d["pending"] = {"id": cid, "need": max(0, d["sent"] - d["seen"]) + 1, "after": 0, "bridge": list(self.b.pid_start())}
            self.st.save(d)
            sent = self.b.command(n)
            if sent in ("blocked", "failed"):
                d["pending"] = None
                self.st.save(d)
                return self._answer(sent, cid, previous)
            if not self._wait(d, wait_s) or not self._settle(d):
                return self._answer("no_journal", cid, previous)
            if d["pending"]:
                got = self._answer("unconfirmed", cid, previous)
                got["pending_command"] = cid
                return got
            status, d["last"] = d["last"]["status"], None
            self.st.save(d)
            return self._answer(status, cid, previous, before)

    def reconcile(self):
        """What is known now. Sends nothing."""
        self.activity = []
        with self.st.locked():
            d = self.st.load()
            ok = self._sync(d)
            last, d["last"] = d["last"], None
            self.st.save(d)
            return {"pending_command": d["pending"]["id"] if d["pending"] else None, "last": last, "journal": ok,
                    "other_activity": self.activity}

    def parity(self):
        """An odd number of barriers left the toggle flipped: one more, when nothing else is going on."""
        with self.st.locked():
            d = self.st.load()
            if not self._sync(d):
                return
            self.st.save(d)
            if d["pending"] or d["seen"] % 2 == 0 or self.now() - d["last_record"] < QUIET_S:
                return
            self._send_barrier(d)

    def uia_begin(self):
        """True: this client may walk the tree now. Recorded first, so a crash in the walk is seen by the next client."""
        with self.st.locked():
            d = self.st.load()
            u = d["uia"]
            if u["owner"]:
                if self.b.alive(*u["owner"]):
                    return False
                self._quarantine(u)
                self.st.save(d)
            if self.now() < u["until"] or not self.b.state()["responds"]:
                return False
            u["owner"] = list(self.b.pid_start())
            self.st.save(d)
            return True

    def uia_end(self, ok):
        with self.st.locked():
            d = self.st.load()
            u = d["uia"]
            if ok:
                u.update(owner=None, until=0, wait=UIA_WAIT_S)
            else:
                self._quarantine(u)
            self.st.save(d)

    def _quarantine(self, u):
        u.update(owner=None, until=self.now() + u["wait"], wait=u["wait"] * 2)
