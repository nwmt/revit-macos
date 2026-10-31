# SPDX-License-Identifier: MIT
"""tools/ui_server.py with a fake bridge, fake Mac and journal files made here. Run with the other unit tests. The
command numbers here are made up."""
import base64, json, os, shutil, subprocess, sys, tempfile, time, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import ui_commands  # noqa: E402
import ui_server  # noqa: E402

BUILD = "20990101_0101"
MAIN = {"main": "aa", "title": "Autodesk Revit 2099 - [a.rvt]", "enabled": True, "responds": True,
        "rect": (10, 20, 3010, 2020), "dialogs": []}


class Bridge:
    def __init__(self):
        self.s = dict(MAIN)
        self.calls, self.controls, self.nodes, self.reply = [], [], [], "posted"
        self.tree_status, self.back = "complete", None

    def state(self):
        return dict(self.s)

    def command(self, n):
        self.calls.append(("command", n))
        return self.reply

    def dialog(self, h):
        return self.controls

    def tree(self, h, depth, limit):
        self.calls.append(("tree", h, depth, limit))
        return self.nodes, self.tree_status

    def press(self, h):
        self.calls.append(("press", h))
        return "ok", "pressed"

    def settext(self, h, text):
        self.calls.append(("settext", h, text))
        return "ok", self.back if self.back is not None else text

    def click(self, h, x, y, kind):
        self.calls.append(("click", h, x, y, kind))
        return "ok", "restored"

    def pid_start(self):
        return (50, "t")

    def alive(self, pid, start):
        return (pid, start) == (50, "t")

    def terminate_old(self, pid, start):
        return True


class Mac:
    def __init__(self):
        self.idle, self.button, self.shot = 60.0, False, (1500, 1000)

    def window_id(self, pid, title):
        return None if title.startswith("Gone") else 77

    def screenshot(self, window, dst):
        with open(dst, "wb") as f:
            f.write(b"png")
        return self.shot

    def idle_seconds(self):
        return self.idle

    def button_down(self):
        return self.button


class Case(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        os.mkdir(os.path.join(self.d, "revit-macos"))
        jd = os.path.join(self.d, "drive_c", "users", "crossover", "AppData", "Local", "Autodesk", "Revit",
                          "Autodesk Revit 2099", "Journals")
        os.makedirs(jd)
        self.journal = os.path.join(jd, "journal.0001.txt")
        self.log("' Build: %s(x64)\n" % BUILD)
        self.b, self.m = Bridge(), Mac()
        self.t = 1000.0
        self.srv = self.server()

    def server(self, write=True, year=2099):
        cfg = ui_server.Config(bottle=self.d, year=year, revit_pid=9, revit_start="s", write=write)
        return ui_server.Server(cfg, self.b, self.m, now=lambda: self.t, sleep=self.sleep)

    def sleep(self, s):
        self.t += s

    def log(self, text):
        with open(self.journal, "a") as f:
            f.write(text)

    def table(self, rows="ID_FAKE_WALL\t1001\nID_FAKE_DOOR\t1002\nID_APP_EXIT\t1003\nID_TOGGLE_ALLOW_PINNED_SELECTION\t1004\n"):
        p = ui_commands.path(self.d, BUILD)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write("# %s\n%s" % (BUILD, rows))

    def call(self, name, **args):
        r = self.srv.call(name, args)
        return json.loads(r[0]["text"])

    def ran(self, cid):
        def command(n):
            self.b.calls.append(("command", n))
            self.log('  Jrn.Command "Internal"  , "x , %s" \n' % cid)
            return "posted"
        self.b.command = command


class Protocol(Case):
    def rpc(self, method, params=None, i=1):
        return self.srv.handle({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}})

    def test_initialize_answers_the_clients_version(self):
        got = self.rpc("initialize", {"protocolVersion": "2099-01-01"})
        self.assertEqual(got["result"]["protocolVersion"], "2099-01-01")
        self.assertIn("tools", got["result"]["capabilities"])

    def test_tools_list_has_every_tool(self):
        names = {t["name"] for t in self.rpc("tools/list")["result"]["tools"]}
        self.assertEqual(names, set("ui_state ui_dialog ui_tree ui_screenshot ui_commands run_command press_button set_text "
                                    "click run_file_command".split()))

    def test_a_notification_gets_no_answer(self):
        self.assertIsNone(self.srv.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_an_unknown_method(self):
        self.assertIn("error", self.rpc("nonsense"))

    def test_an_unknown_tool(self):
        got = self.rpc("tools/call", {"name": "nope", "arguments": {}})
        self.assertTrue(got["result"]["isError"])

    def test_a_wrong_argument_is_an_error_not_a_crash(self):
        self.table()
        got = self.rpc("tools/call", {"name": "click", "arguments": {"window": "aa", "x": "a", "y": 1}})
        self.assertTrue(got["result"]["isError"])


class State(Case):
    def test_state(self):
        self.table()
        got = self.call("ui_state")
        self.assertEqual(got["build"], BUILD)
        self.assertEqual(got["commands"], "ready")
        self.assertIsNone(got["pending_command"])

    def test_window_text_with_tabs_quotes_and_cyrillic_stays_json(self):
        self.b.s["dialogs"] = [{"hwnd": "bb", "cls": "#32770", "title": '\u041e\u043a\u043d\u043e "1"', "enabled": True, "modeless": False,
                                "rect": (0, 0, 1, 1)}]
        got = self.call("ui_state")
        self.assertEqual(got["dialogs"][0]["title"], '\u041e\u043a\u043d\u043e "1"')
        self.assertIn("untrusted", got)

    def test_state_sends_nothing(self):
        self.table()
        self.log('  Jrn.Command "Internal"  , " , ID_TOGGLE_ALLOW_PINNED_SELECTION" \n')
        self.t += 100
        self.call("ui_state")
        self.assertEqual(self.b.calls, [])


class Commands(Case):
    def test_a_command(self):
        self.table()
        self.ran("ID_FAKE_WALL")
        self.assertEqual(self.call("run_command", id="ID_FAKE_WALL")["status"], "ran")
        self.assertEqual(self.b.calls, [("command", 1001)])

    def test_a_dangerous_command_needs_the_other_tool(self):
        self.table()
        got = self.call("run_command", id="ID_APP_EXIT")
        self.assertEqual(got["status"], "refused")
        self.assertIn("run_file_command", got["why"])
        self.assertEqual(self.b.calls, [])

    def test_the_file_tool_takes_only_dangerous_commands(self):
        self.table()
        self.assertEqual(self.call("run_file_command", id="ID_FAKE_WALL")["status"], "refused")

    def test_the_file_tool_runs_a_dangerous_command(self):
        self.table()
        self.ran("ID_APP_EXIT")
        self.assertEqual(self.call("run_file_command", id="ID_APP_EXIT")["status"], "ran")

    def test_outside_the_table(self):
        self.table()
        self.assertEqual(self.call("run_command", id="ID_FAKE_NONE")["status"], "refused")

    def test_a_missing_table_says_what_to_do(self):
        got = self.call("run_command", id="ID_FAKE_WALL")
        self.assertEqual(got["status"], "refused")
        self.assertIn("./revit mcp commands", got["why"])

    def test_a_broken_table_gives_its_reason(self):
        os.makedirs(ui_commands.folder(self.d))
        with open(ui_commands.error_path(self.d, BUILD), "w") as f:
            f.write("ShortcutsHelper is gone")
        self.assertIn("ShortcutsHelper", self.call("run_command", id="ID_FAKE_WALL")["why"])

    def test_an_unknown_build_runs_nothing(self):
        with open(self.journal, "w") as f:
            f.write("' no build line here\n")
        self.table()
        self.srv = self.server()
        self.assertEqual(self.call("run_command", id="ID_FAKE_WALL")["status"], "refused")
        self.assertEqual(self.b.calls, [])

    def test_search(self):
        self.table()
        self.assertEqual(self.call("ui_commands", words="wall")["ids"], ["ID_FAKE_WALL"])


class Dialogs(Case):
    WIN32 = {"hwnd": "bb", "cls": "#32770", "title": "Warning", "enabled": True, "modeless": False, "rect": (0, 0, 9, 9)}
    WPF = {"hwnd": "cc", "cls": "HwndWrapper[x]", "title": "Shortcuts", "enabled": True, "modeless": False,
           "rect": (100, 100, 900, 900)}

    def test_a_button_by_its_text(self):
        self.b.s["dialogs"] = [self.WIN32]
        self.b.controls = [{"hwnd": "b1", "cls": "Button", "text": "&Close", "enabled": True}]
        self.assertEqual(self.call("press_button", dialog="bb", button="Close")["status"], "ok")
        self.assertEqual(self.b.calls, [("press", "b1")])

    def test_a_button_that_is_not_there(self):
        self.b.s["dialogs"] = [self.WIN32]
        self.assertEqual(self.call("press_button", dialog="bb", button="Close")["status"], "refused")

    def test_a_wpf_button_by_automation_id_is_a_click(self):
        self.b.s["dialogs"] = [self.WPF]
        self.b.nodes = [{"control": 50000, "name": "", "aid": "mOkButton", "cls": "Button", "enabled": True, "rect": (200, 300, 400, 500)}]
        self.assertEqual(self.call("press_button", dialog="cc", button="mOkButton")["status"], "ok")
        self.assertEqual(self.b.calls[-1], ("click", "cc", 300, 400, "left"))

    def test_a_wpf_button_waits_for_a_person(self):
        self.b.s["dialogs"] = [self.WPF]
        self.b.nodes = [{"control": 50000, "name": "OK", "aid": "", "cls": "Button", "enabled": True, "rect": (200, 300, 400, 500)}]
        self.m.idle = 0.0
        self.assertEqual(self.call("press_button", dialog="cc", button="OK")["status"], "user_active")

    def test_a_dialog_that_is_not_open(self):
        self.assertEqual(self.call("press_button", dialog="zz", button="OK")["status"], "refused")

    def test_set_text(self):
        self.b.s["dialogs"] = [self.WIN32]
        self.b.controls = [{"hwnd": "e1", "cls": "Edit", "text": "", "enabled": True}]
        self.assertEqual(self.call("set_text", dialog="bb", field="e1", text="C:\\\u0442\u0435\u0441\u0442.rvt")["status"], "ok")

    def test_text_that_did_not_stick(self):
        self.b.s["dialogs"] = [self.WIN32]
        self.b.controls = [{"hwnd": "e1", "cls": "Edit", "text": "", "enabled": True}]
        self.b.back = "other"
        self.assertEqual(self.call("set_text", dialog="bb", field="e1", text="x")["status"], "not_applied")

    def test_text_in_a_wpf_dialog_is_not_supported(self):
        self.b.s["dialogs"] = [self.WPF]
        self.assertEqual(self.call("set_text", dialog="cc", field="e1", text="x")["status"], "unsupported")

    def test_a_tab_in_the_text_is_refused(self):
        self.b.s["dialogs"] = [self.WIN32]
        self.b.controls = [{"hwnd": "e1", "cls": "Edit", "text": "", "enabled": True}]
        self.assertEqual(self.call("set_text", dialog="bb", field="e1", text="a\tb")["status"], "refused")


class Tree(Case):
    def test_defaults(self):
        self.call("ui_tree")
        self.assertEqual(self.b.calls, [("tree", "aa", 6, 400)])

    def test_busy_quarantines_for_the_next_client(self):
        self.b.tree_status = "busy"
        self.assertEqual(self.call("ui_tree")["status"], "busy")
        self.assertEqual(self.server().call("ui_tree", {}) and self.call("ui_tree")["status"], "busy")
        self.assertEqual(len([c for c in self.b.calls if c[0] == "tree"]), 1)


class Click(Case):
    def shot(self):
        r = self.srv.call("ui_screenshot", {})
        self.assertEqual(r[1]["type"], "image")
        self.assertEqual(base64.b64decode(r[1]["data"]), b"png")
        return json.loads(r[0]["text"])

    def test_a_click_goes_through_the_picture(self):
        got = self.shot()
        self.assertEqual((got["width"], got["height"]), (1500, 1000))
        self.assertEqual(self.call("click", window="aa", x=150, y=100)["status"], "ok")
        self.assertEqual(self.b.calls[-1], ("click", "aa", 310, 220, "left"))

    def test_no_picture_no_click(self):
        self.assertEqual(self.call("click", window="aa", x=1, y=1)["status"], "refused")

    def test_the_window_moved_since_the_picture(self):
        self.shot()
        self.b.s["rect"] = (50, 20, 3050, 2020)
        self.assertEqual(self.call("click", window="aa", x=1, y=1)["status"], "refused")
        self.assertEqual(self.b.calls, [])

    def test_a_window_that_closed_since_the_picture(self):
        self.shot()
        self.b.s["main"] = "dd"
        self.assertEqual(self.call("click", window="aa", x=1, y=1)["status"], "refused")

    def test_a_point_outside(self):
        self.shot()
        self.assertEqual(self.call("click", window="aa", x=5000, y=1)["status"], "refused")

    def test_a_person_at_the_mouse(self):
        self.shot()
        self.m.idle = 0.0
        self.assertEqual(self.call("click", window="aa", x=1, y=1)["status"], "user_active")
        self.assertEqual(self.b.calls, [])

    def test_a_held_button(self):
        self.shot()
        self.m.button = True
        self.assertEqual(self.call("click", window="aa", x=1, y=1)["status"], "user_active")

    def test_a_picture_of_a_window_with_no_mac_window(self):
        self.b.s["title"] = "Gone"
        self.assertEqual(json.loads(self.srv.call("ui_screenshot", {})[0]["text"])["status"], "refused")


class Close(Case):
    def test_read_only_never_sends(self):
        self.table()
        self.log('  Jrn.Command "Internal"  , " , ID_TOGGLE_ALLOW_PINNED_SELECTION" \n')
        srv = self.server(write=False)
        srv.call("ui_state", {})
        self.t += 100
        srv.close()
        self.assertEqual(self.b.calls, [])

    def test_a_write_connection_evens_the_toggle_on_the_way_out(self):
        self.table()
        self.log('  Jrn.Command "Internal"  , " , ID_TOGGLE_ALLOW_PINNED_SELECTION" \n')
        self.srv.call("ui_state", {})
        self.t += 100
        self.srv.close()
        self.assertEqual(self.b.calls, [("command", 1004)])


class Main(unittest.TestCase):
    def test_the_lock_fd_is_closed_before_the_bridge_starts(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        fake = os.path.join(d, "bridge")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\nls -l /dev/fd > "%s/fds"\necho "hello 1 0 0 1 1"\nread x\n' % d)
        os.chmod(fake, 0o755)
        r, w = os.pipe()
        tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "ui_server.py")
        p = subprocess.Popen([sys.executable, "-I", "-B", tool, "revit-macos-ui-server", d, "--year", "2099", "--revit-pid", "1",
                              "--write", "0", "--lock-fd", str(r), "--bridge", fake], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, pass_fds=(r,))
        os.close(r)
        deadline = time.time() + 10
        while not os.path.exists(d + "/fds") and time.time() < deadline:
            time.sleep(0.05)
        p.stdin.close()
        p.wait(timeout=10)
        p.stdout.close()
        os.close(w)
        with open(d + "/fds") as f:
            self.assertNotIn(" %d -> " % r, f.read())


if __name__ == "__main__":
    unittest.main()
