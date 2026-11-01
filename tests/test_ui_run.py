# SPDX-License-Identifier: MIT
"""tools/ui_run.py: the states of a command, with a fake bridge, a fake journal and a fake clock. Run with the other
unit tests. The numbers here are made up."""
import json, os, shutil, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import ui_journal  # noqa: E402
import ui_run  # noqa: E402

X, Y, B = "ID_FAKE_WALL", "ID_FAKE_DOOR", "ID_FAKE_BARRIER"
NUM = {X: 1001, Y: 1002, B: 1003}


class Table:
    def number(self, c):
        return NUM.get(c)


class Journal:
    """Rec list; a reader's offset is an index."""

    def __init__(self):
        self.recs, self.gone = [], False

    def add(self, cid, label="Internal"):
        self.recs.append(ui_journal.Rec(label, cid))

    def reader(self, offset, identity):
        return Reader(self, offset)


class Reader:
    def __init__(self, j, offset):
        self.j, self.offset, self.identity, self.lost = j, offset or 0, ("dev", 1), False

    def read(self):
        if self.j.gone:
            self.lost = True
            return []
        new = self.j.recs[self.offset:]
        self.offset = len(self.j.recs)
        return new


class Clock:
    def __init__(self):
        self.t, self.at = 1000.0, []

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s
        for when, fn in list(self.at):
            if self.t >= when:
                self.at.remove((when, fn))
                fn()

    def after(self, s, fn):
        self.at.append((self.t + s, fn))


class Bridge:
    """Records what was sent; on_command plays what Revit would do."""

    def __init__(self, journal=None, ident=(50, 500.0)):
        self.sent, self.journal, self.ident = [], journal, ident
        self.main_enabled, self.answers, self.dialogs = True, True, []
        self.reply = {}          # number -> blocked|failed|lost
        self.on_command = None
        self.killed, self.can_kill, self.alive_set = [], True, set()

    def state(self):
        return {"main": 1, "enabled": self.main_enabled, "responds": self.answers, "dialogs": list(self.dialogs)}

    def command(self, n):
        r = self.reply.get(n, "posted")
        if r in ("posted", "lost"):
            self.sent.append(n)
            if self.on_command:
                self.on_command(n)
        return r

    def pid_start(self):
        return self.ident

    def alive(self, pid, start):
        return (pid, start) in self.alive_set or (pid, start) == self.ident

    def terminate_old(self, pid, start):
        self.killed.append((pid, start))
        return self.can_kill


class Case(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        os.mkdir(os.path.join(self.d, "revit-macos"))
        self.j, self.c = Journal(), Clock()
        self.b = Bridge(self.j)
        self.r = self.runner()

    def runner(self, bridge=None, generation="g1"):
        return ui_run.Runner(ui_run.State(self.d, generation), bridge or self.b, self.j.reader, Table(), self.c.now,
                             self.c.sleep, B)

    def echo(self, *ids):   # Revit runs what comes in, for these ids
        def play(n):
            for i in ids:
                if NUM[i] == n:
                    self.j.add(i)
        self.b.on_command = play

    def data(self):
        with open(os.path.join(self.d, "revit-macos", "ui.json")) as f:
            return json.load(f)


class Plain(Case):
    def test_a_command_that_runs(self):
        self.echo(X)
        self.assertEqual(self.r.run(X, 10)["status"], "ran")
        self.assertEqual(self.b.sent, [1001])
        self.assertIsNone(self.data()["pending"])

    def test_a_dialog_open_sends_nothing(self):
        self.b.main_enabled = False
        self.b.dialogs = [{"hwnd": 7, "title": "Warning", "enabled": True}]
        got = self.r.run(X, 10)
        self.assertEqual(got["status"], "blocked")
        self.assertEqual(got["dialogs"][0]["title"], "Warning")
        self.assertEqual(self.b.sent, [])

    def test_revit_not_answering_sends_nothing(self):
        self.b.answers = False
        self.assertEqual(self.r.run(X, 10)["status"], "blocked")
        self.assertEqual(self.b.sent, [])

    def test_the_bridge_refuses_at_the_last_moment(self):
        self.b.reply[1001] = "blocked"
        self.assertEqual(self.r.run(X, 10)["status"], "blocked")
        self.assertIsNone(self.data()["pending"])

    def test_postmessage_fails(self):
        self.b.reply[1001] = "failed"
        self.assertEqual(self.r.run(X, 10)["status"], "failed")
        self.assertIsNone(self.data()["pending"])

    def test_the_barrier_id_is_refused(self):
        self.assertEqual(self.r.run(B, 10)["status"], "refused")
        self.assertEqual(self.b.sent, [])

    def test_an_id_outside_the_table_is_refused(self):
        self.assertEqual(self.r.run("ID_FAKE_NONE", 10)["status"], "refused")

    def test_no_table(self):
        r = ui_run.Runner(ui_run.State(self.d, "g1"), self.b, self.j.reader, None, self.c.now, self.c.sleep, B)
        self.assertEqual(r.run(X, 10)["status"], "refused")
        self.assertEqual(self.b.sent, [])

    def test_the_record_is_on_disk_before_the_message_goes(self):
        seen = {}
        self.b.on_command = lambda n: seen.update(self.data())
        self.j.add(X)
        self.r.run(X, 1)
        self.assertEqual(seen["pending"]["id"], X)

    def test_a_late_record_closes_it_on_the_next_call(self):
        self.b.reply[1003] = "blocked"
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")
        self.j.add(X)
        got = self.r.reconcile()
        self.assertEqual(got["last"], {"id": X, "status": "ran"})
        self.assertIsNone(got["pending_command"])

    def test_the_same_id_from_a_person_does_not_close_it(self):
        self.b.reply[1003] = "blocked"
        self.r.run(X, 1)
        self.j.add(X, "Ribbon")
        got = self.r.reconcile()
        self.assertEqual(got["pending_command"], X)
        self.assertEqual(got["other_activity"], ["Ribbon " + X])

    def test_other_records_are_reported_and_harmless(self):
        def play(n):
            self.j.add(Y, "KeyboardShortcut")
            self.j.add(X)
        self.b.on_command = play
        got = self.r.run(X, 10)
        self.assertEqual(got["status"], "ran")
        self.assertEqual(got["other_activity"], ["KeyboardShortcut " + Y])

    def test_a_lost_journal(self):
        self.j.gone = True
        self.assertEqual(self.r.run(X, 1)["status"], "no_journal")

    def test_a_journal_lost_after_sending_is_never_ran(self):
        def play(n):
            self.j.gone = True
        self.b.on_command = play
        got = self.r.run(X, 1)
        self.assertEqual(got["status"], "no_journal")
        self.assertEqual(self.data()["pending"]["id"], X)

    def test_an_ordinary_command_dialog_is_not_overlap(self):
        def play(n):
            self.j.add(X)
            self.b.main_enabled = False
            self.b.dialogs = [{"hwnd": 7, "title": "Its dialog", "enabled": True}]
        self.b.on_command = play
        got = self.r.run(X, 10)
        self.assertFalse(got["overlapped"])
        self.assertEqual(len(got["dialogs"]), 1)

    def test_a_disabled_dialog_is_overlap(self):
        def play(n):
            self.j.add(X)
            self.b.dialogs = [{"hwnd": 7, "title": "Under", "enabled": False}, {"hwnd": 8, "title": "Over", "enabled": True}]
        self.b.on_command = play
        self.assertTrue(self.r.run(X, 10)["overlapped"])


    def test_a_palette_greyed_by_the_commands_dialog_is_not_overlap(self):
        palette = {"hwnd": 5, "title": "pyRevit", "enabled": True}
        self.b.dialogs = [palette]
        def play(n):
            self.j.add(X)
            self.b.dialogs = [dict(palette, enabled=False), {"hwnd": 7, "title": "Its dialog", "enabled": True}]
        self.b.on_command = play
        self.assertFalse(self.r.run(X, 10)["overlapped"])

    def test_the_answer_waits_for_the_dialog_the_journal_announced(self):
        def show():
            self.b.dialogs = [{"hwnd": 7, "title": "Slow dialog", "enabled": True}]
        def play(n):
            self.j.add(X)
            self.c.after(1.0, show)
        self.b.on_command = play
        self.assertEqual(self.r.run(X, 10)["dialogs"][0]["title"], "Slow dialog")

    def test_a_command_without_a_dialog_does_not_wait_long(self):
        self.echo(X)
        t0 = self.c.t
        self.r.run(X, 10)
        self.assertLess(self.c.t - t0, 2.5)


class Barrier(Case):
    def test_nothing_recorded_then_barrier_means_not_run(self):
        self.echo(B)
        self.assertEqual(self.r.run(X, 1)["status"], "not_run")
        self.assertEqual(self.b.sent, [1001, 1003])
        self.assertIsNone(self.data()["pending"])

    def test_x_before_the_barrier_is_ran(self):
        def play(n):
            if n == 1003:
                self.j.add(X)
                self.j.add(B)
        self.b.on_command = play
        self.assertEqual(self.r.run(X, 1)["status"], "ran")

    def test_an_old_barrier_in_the_queue_does_not_prove_anything(self):
        self.r.run(Y, 1)                       # no record at all: Y and a barrier are out, unseen
        self.j.add(Y)                          # Y resolves; its barrier is still queued
        self.r.reconcile()
        def play(n):                           # the old barrier shows up, the new one does not yet
            if n == 1003 and not any(r.command == B for r in self.j.recs):
                self.j.add(B)
        self.b.on_command = play
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")
        self.assertEqual(self.data()["pending"]["id"], X)

    def test_two_barriers_are_enough_with_one_in_flight(self):
        self.r.run(Y, 1)
        self.j.add(Y)
        self.r.reconcile()
        self.echo(B)
        self.j.add(B)                          # the old one
        got = self.r.run(X, 1)
        self.assertEqual(got["status"], "not_run")

    def test_a_lost_barrier_answer_gives_no_false_not_run(self):
        self.b.reply[1003] = "lost"
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")
        self.assertEqual(self.data()["sent"], 1)

    def test_a_lost_barrier_is_made_up_for_later(self):
        self.b.reply[1003] = "lost"
        self.r.run(X, 1)
        del self.b.reply[1003]
        self.echo(B)
        got = self.r.run(Y, 1)                 # the old barrier never came: one more, and then it is settled
        self.assertEqual(got["previous"], {"id": X, "status": "not_run"})

    def test_a_refused_barrier_is_not_counted(self):
        self.b.reply[1003] = "blocked"
        self.r.run(X, 1)
        self.assertEqual(self.data()["sent"], 0)

    def test_no_barrier_while_a_dialog_is_open(self):
        def play(n):
            self.b.main_enabled = False
        self.b.on_command = play
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")
        self.assertEqual(self.b.sent, [1001])

    def test_no_barrier_when_revit_does_not_answer(self):
        def play(n):
            self.b.answers = False
        self.b.on_command = play
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")
        self.assertEqual(self.b.sent, [1001])


class Shared(Case):
    def unresolved(self):
        self.b.reply[1003] = "blocked"
        self.assertEqual(self.r.run(X, 1)["status"], "unconfirmed")

    def test_a_second_client_sees_it(self):
        self.unresolved()
        other = Bridge(self.j, (51, 501.0))
        other.reply[1003] = "blocked"
        got = self.runner(other).run(Y, 1)
        self.assertEqual(got["status"], "pending")
        self.assertEqual(got["pending_command"], X)
        self.assertEqual(other.sent, [])

    def test_a_reconnected_client_sees_it(self):
        self.unresolved()
        self.assertEqual(self.runner().reconcile()["pending_command"], X)

    def test_pending_sends_no_second_command(self):
        self.unresolved()
        self.r.run(X, 1)
        self.assertEqual(self.b.sent.count(1001), 1)

    def test_a_crash_between_the_record_and_the_message_stays_uncertain(self):
        st = ui_run.State(self.d, "g1")
        with st.locked():
            d = st.load()
            d["pending"] = {"id": X, "need": 1, "after": 0, "bridge": [50, 500.0]}
            st.save(d)
        self.assertEqual(self.runner().reconcile()["pending_command"], X)

    def test_a_stuck_bridge_is_ended_before_the_first_barrier(self):
        self.unresolved()
        other = Bridge(self.j, (51, 501.0))
        other.alive_set.add((50, 500.0))
        other.on_command = lambda n: self.j.add(B) if n == 1003 else None
        got = self.runner(other).run(Y, 1)
        self.assertEqual(other.killed, [(50, 500.0)])
        self.assertEqual(got["previous"], {"id": X, "status": "not_run"})

    def test_a_bridge_that_cannot_be_ended_means_no_barrier(self):
        self.unresolved()
        other = Bridge(self.j, (51, 501.0))
        other.alive_set.add((50, 500.0))
        other.can_kill = False
        self.assertEqual(self.runner(other).run(Y, 1)["status"], "pending")
        self.assertEqual(other.sent, [])

    def test_a_dead_old_bridge_needs_no_ending(self):
        self.unresolved()
        other = Bridge(self.j, (51, 501.0))
        other.on_command = lambda n: self.j.add(B) if n == 1003 else None
        self.runner(other).run(Y, 1)
        self.assertEqual(other.killed, [])

    def test_a_new_revit_forgets_it(self):
        self.unresolved()
        self.assertIsNone(self.runner(generation="g2").reconcile()["pending_command"])

    def test_reconcile_sends_nothing(self):
        self.unresolved()
        self.c.sleep(100)
        self.j.add(B)
        self.r.reconcile()
        self.assertEqual(self.b.sent, [1001])


class Parity(Case):
    def test_an_odd_count_after_quiet_gets_one_more(self):
        self.echo(B)
        self.r.run(X, 1)
        self.assertEqual(self.data()["seen"], 1)
        self.c.sleep(21)
        self.b.sent.clear()
        self.r.parity()
        self.assertEqual(self.b.sent, [1003])

    def test_not_before_the_quiet(self):
        self.echo(B)
        self.r.run(X, 1)
        self.b.sent.clear()
        self.r.parity()
        self.assertEqual(self.b.sent, [])

    def test_not_with_a_command_pending(self):
        self.j.add(B)
        self.r.reconcile()
        self.b.reply[1003] = "lost"
        self.b.reply[1001] = "lost"
        self.r.run(X, 1)
        self.c.sleep(21)
        self.b.sent.clear()
        self.r.parity()
        self.assertEqual(self.b.sent, [])

    def test_an_even_count_needs_nothing(self):
        self.j.add(B)
        self.j.add(B)
        self.r.reconcile()
        self.c.sleep(21)
        self.r.parity()
        self.assertEqual(self.b.sent, [])

    def test_a_dialog_waits(self):
        self.j.add(B)
        self.r.reconcile()
        self.c.sleep(21)
        self.b.main_enabled = False
        self.r.parity()
        self.assertEqual(self.b.sent, [])


class Uia(Case):
    def test_one_at_a_time(self):
        self.assertTrue(self.r.uia_begin())
        self.assertFalse(self.r.uia_begin())

    def test_a_second_client_waits_for_the_first(self):
        self.assertTrue(self.r.uia_begin())
        other = Bridge(self.j, (51, 501.0))
        other.alive_set.add((50, 500.0))
        self.assertFalse(self.runner(other).uia_begin())

    def test_done_frees_it(self):
        self.r.uia_begin()
        self.r.uia_end(True)
        self.assertTrue(self.r.uia_begin())

    def test_busy_quarantines_for_120_s(self):
        self.r.uia_begin()
        self.r.uia_end(False)
        self.c.sleep(119)
        self.assertFalse(self.r.uia_begin())
        self.c.sleep(2)
        self.assertTrue(self.r.uia_begin())

    def test_a_second_busy_doubles_it(self):
        self.r.uia_begin()
        self.r.uia_end(False)
        self.c.sleep(121)
        self.r.uia_begin()
        self.r.uia_end(False)
        self.c.sleep(200)
        self.assertFalse(self.r.uia_begin())
        self.c.sleep(41)
        self.assertTrue(self.r.uia_begin())

    def test_a_lost_owner_quarantines(self):
        self.r.uia_begin()
        other = Bridge(self.j, (51, 501.0))     # the first bridge died in the middle of its walk
        r = self.runner(other)
        self.assertFalse(r.uia_begin())
        self.c.sleep(121)
        self.assertTrue(r.uia_begin())

    def test_a_new_client_sees_the_quarantine(self):
        self.r.uia_begin()
        self.r.uia_end(False)
        self.assertFalse(self.runner(Bridge(self.j, (51, 501.0))).uia_begin())

    def test_revit_must_answer(self):
        self.b.answers = False
        self.assertFalse(self.r.uia_begin())


if __name__ == "__main__":
    unittest.main()
