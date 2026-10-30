# SPDX-License-Identifier: MIT
"""tools/mcp_gate.py against a fake scripts/mcp-launch.sh that speaks MCP. Run with the other unit tests."""
import hashlib, importlib.util, json, os, pty, queue, signal, stat, subprocess, sys, tempfile, textwrap, threading, time
import unittest, zipfile

GATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "mcp_gate.py")
spec = importlib.util.spec_from_file_location("mcp_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAKE = """#!/usr/bin/env python3
import json, os, signal, sys, time
d = os.environ["FAKE_DIR"]; mode = os.environ.get("FAKE_MODE", "")
open(d + "/argv", "w").write(json.dumps(sys.argv[1:]))
open(d + "/env", "w").write(json.dumps(dict(os.environ)))
def out(m):
    sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
if mode == "noise":
    print("banner of a server"); sys.stdout.flush()
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, lambda *a: None)
for line in sys.stdin:
    open(d + "/seen", "a").write(line)
    m = json.loads(line); i = m.get("id"); method = m.get("method")
    if method == "initialize":
        out({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": "2025-11-25", "serverInfo": {"name": "fake"},
             "capabilities": {"tools": {"listChanged": True}, "resources": {}, "prompts": {}, "tasks": {}}}})
        if mode == "sampling":
            out({"jsonrpc": "2.0", "id": 900, "method": "sampling/createMessage", "params": {}})
            out({"jsonrpc": "2.0", "id": 901, "method": "ping"})
    elif method == "tools/list":
        out({"jsonrpc": "2.0", "id": i, "result": {"tools": [{"name": n} for n in os.environ["FAKE_TOOLS"].split()],
             "nextCursor": "more"}})
    elif method == "tools/call":
        text = "x" * (5 << 20) if mode == "big" else "done"
        out({"jsonrpc": "2.0", "id": i, "result": {"content": [{"type": "text", "text": text}]}})
    elif i is not None and method:
        out({"jsonrpc": "2.0", "id": i, "result": {}})
if mode == "hang-after-eof":
    signal.signal(signal.SIGTERM, lambda *a: os._exit(143))
    time.sleep(60)
sys.exit(int(os.environ.get("FAKE_RC", "0")))
"""


class World(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.data = os.path.join(self.d, "data")
        self.root = os.path.join(self.d, "root")
        os.makedirs(self.root + "/scripts")
        p = self.root + "/scripts/mcp-launch.sh"
        open(p, "w").write(FAKE)
        os.chmod(p, 0o755)
        self.procs, self.lines = [], {}

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            for f in (p.stdin, p.stdout, p.stderr):
                try:
                    f.close()
                except OSError:
                    pass
        self.tmp.cleanup()

    def token(self, tier="read", server="autodesk", bottle="rvt2027-a", name="t"):
        return gate.create_token(self.data, name, "2027", bottle, server, tier)

    def start(self, token, server="autodesk", tools="a b", mode="", policy="", bottle="rvt2027-a", env=None):
        e = {k: v for k, v in os.environ.items() if k != gate.TOKEN_ENV}
        e.update(FAKE_DIR=self.d, FAKE_MODE=mode, FAKE_TOOLS=tools)
        if token is not None:
            e[gate.TOKEN_ENV] = token
        e.update(env or {})
        p = subprocess.Popen([sys.executable, "-I", "-B", GATE, "serve", gate.MARKER, "/b", "--root", self.root,
                              "--data", self.data, "--year", "2027", "--bottle", bottle, "--server", server,
                              "--policy", policy], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=e, cwd="/")
        self.procs.append(p)
        return p

    def send(self, p, m):
        p.stdin.write((m if isinstance(m, bytes) else json.dumps(m).encode()) + b"\n")
        p.stdin.flush()

    def recv(self, p, wait=10):
        if p not in self.lines:   # a thread: two answers may arrive in one chunk, which select cannot see
            q = self.lines[p] = queue.Queue()
            threading.Thread(target=lambda: [q.put(x) for x in iter(p.stdout.readline, b"")], daemon=True).start()
        return json.loads(self.lines[p].get(timeout=wait))

    def call(self, p, i, name, args=None):
        self.send(p, {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
        return self.recv(p)

    def seen(self):
        try:
            return [json.loads(x) for x in open(self.d + "/seen")]
        except FileNotFoundError:
            return []

    def audit(self, bottle="rvt2027-a"):
        return [json.loads(x) for x in open(os.path.join(self.data, "mcp", "audit", bottle + ".jsonl"))]

    def wait_for(self, cond, secs=6):
        end = time.time() + secs
        while time.time() < end:
            if cond():
                return True
            time.sleep(0.05)
        return False


class Tokens(World):
    def test_only_the_hash_is_on_disk_and_files_are_private(self):
        t = self.token()
        path = os.path.join(self.data, "mcp", "tokens.json")
        self.assertNotIn(t, open(path).read())
        self.assertEqual(json.load(open(path))[0]["sha256"], hashlib.sha256(t.encode()).hexdigest())
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)

    def test_same_name_replaces(self):
        self.token(name="n")
        t2 = self.token(name="n")
        rows = gate.load_tokens(self.data)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["sha256"], gate.token_sha(t2))

    def test_refusals(self):
        for bad in ("[", '{"a": 1}', '[{"name": "x"}]'):
            open(os.path.join(gate.mcp_dir(self.data), "tokens.json"), "w").write(bad)
            with self.assertRaises(gate.GateError):
                gate.load_tokens(self.data)
        with self.assertRaises(gate.GateError):
            gate.create_token(self.data + "2", "a b", "2027", "x", "python", "read")

    def test_tier_table(self):
        self.assertIsNotNone(gate.tier_problem("pyrevit", "write", False))
        self.assertIsNotNone(gate.tier_problem("autodesk", "code", False))
        self.assertIsNone(gate.tier_problem("autodesk", "code", True))
        self.assertIsNone(gate.tier_problem("python", "code", False))
        self.assertIsNotNone(gate.tier_problem("python", "all", False))

    def run_cli(self, *args, tty):
        cmd = [sys.executable, "-I", "-B", GATE, *args]
        if not tty:
            return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
        m, s = pty.openpty()
        r = subprocess.run(cmd, stdin=s, capture_output=True, text=True)
        os.close(m); os.close(s)
        return r

    def test_issuing_needs_a_terminal(self):
        a = ("token-create", "--root", self.root, "--data", self.data, "--year", "2027", "--bottle", "rvt2027-a",
             "--server", "python", "--tier", "write")
        r = self.run_cli(*a, tty=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn("Terminal", r.stderr)
        self.assertEqual(gate.load_tokens(self.data), [])
        r = self.run_cli(*a, tty=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("claude mcp add", r.stdout)
        self.assertEqual(gate.load_tokens(self.data)[0]["tier"], "write")
        r = self.run_cli("token-list", "--data", self.data, tty=False)
        self.assertIn("rvt2027-a-python-write", r.stdout)
        self.assertNotIn(gate.load_tokens(self.data)[0]["sha256"], r.stdout)
        self.assertEqual(self.run_cli("token-revoke", "--data", self.data, "--name", "nope", tty=False).returncode, 1)
        self.assertEqual(self.run_cli("token-revoke", "--data", self.data, "--name", "rvt2027-a-python-write",
                                      tty=False).returncode, 0)
        self.assertEqual(gate.load_tokens(self.data), [])

    def test_no_token_starts_nothing(self):
        t = self.token()
        for tok, kw in ((None, {}), ("wrong", {}), (t, {"bottle": "rvt2027-b"}), (t, {"server": "python"})):
            p = self.start(tok, **kw)
            self.assertEqual(p.wait(20), 1)
            self.assertEqual(p.stdout.read(), b"")
            self.assertIn(b"./revit mcp token", p.stderr.read())
        self.assertFalse(os.path.exists(self.d + "/argv"))


class Audits(World):
    def test_rotation_and_partial_write(self):
        a = gate.Audit(self.data, "b", max_bytes=2000)
        for i in range(400):
            a.write({"i": i, "pad": "x" * 20})
        names = sorted(os.listdir(a.dir))
        self.assertEqual(names, ["b.jsonl", "b.jsonl.1", "b.jsonl.2", "b.jsonl.3", "b.lock"])
        self.assertLess(os.path.getsize(a.path), 2000)
        real = os.write
        def short(fd, b):
            real(fd, b[:5])
            return 5
        gate.os.write = short
        try:
            with self.assertRaises(OSError):
                a.write({"i": "cut"})
        finally:
            gate.os.write = real
        a.write({"i": "next"})
        self.assertEqual(json.loads(open(a.path).read().splitlines()[-1]), {"i": "next"})

    def test_a_broken_end_stops_writes(self):
        a = gate.Audit(self.data, "b")
        open(a.path, "w").write('{"half')
        with self.assertRaises(OSError):
            a.write({"i": 1})

    def test_two_processes_across_rotation(self):
        code = textwrap.dedent("""
            import importlib.util, sys
            s = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(s)
            s.loader.exec_module(g)
            a = g.Audit(sys.argv[2], "b", max_bytes=20000)
            for i in range(150):
                a.write({"p": sys.argv[3], "i": i, "pad": "y" * 60})
        """)
        ps = [subprocess.Popen([sys.executable, "-I", "-B", "-c", code, GATE, self.data, w]) for w in "ab"]
        for p in ps:
            self.assertEqual(p.wait(60), 0)
        d = os.path.join(self.data, "mcp", "audit")
        rows = [json.loads(x) for f in os.listdir(d) if ".lock" not in f for x in open(os.path.join(d, f))]
        self.assertEqual(len({(r["p"], r["i"]) for r in rows}), 300)


class Tiers(World):
    def test_every_server_and_tier(self):
        cases = [("autodesk", "read", "query_model", "modify_element_parameters"),
                 ("autodesk", "write", "move_elements", "delete_elements"),
                 ("pyrevit", "read", "capture_view", "run_query"),
                 ("pyrevit", "read", "get_context", "run_modify"),
                 ("pyrevit", "read", "list_automation", "run_automation"),
                 ("python", "read", "get_revit_view", "place_family"),
                 ("python", "write", "place_family", "execute_revit_code")]
        for server, tier, ok, no in cases:
            self.assertTrue(gate.tool_allowed(server, tier, ok), ok)
            self.assertFalse(gate.tool_allowed(server, tier, no), no)
            self.assertFalse(gate.tool_allowed(server, tier, "a_new_tool"))
            self.assertTrue(gate.tool_allowed(server, "code", no))

    def test_python_tables_cover_the_twenty_tools(self):
        self.assertEqual(sum(len(s) for s in gate.TOOLS["python"].values()), 19)

    def test_launcher_gets_the_write_flag_of_the_tier(self):
        for tier, flag in (("read", "0"), ("write", "1")):
            p = self.start(self.token(tier))
            self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/argv")))
            p.stdin.close(); p.wait(20)
            self.assertEqual(json.load(open(self.d + "/argv")), ["2027", "rvt2027-a", flag, "autodesk"])
            os.unlink(self.d + "/argv")


class Protocol(World):
    def init(self, p):
        self.send(p, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "cl", "version": "1"}, "capabilities": {"sampling": {}, "roots": {}, "tasks": {}}}})
        return self.recv(p)

    def test_token_stays_out_of_child_env_and_log(self):
        t = self.token("code", "python")
        p = self.start(t, "python", "execute_revit_code")
        self.init(p)
        self.call(p, 2, "execute_revit_code", {"code": "print('%s')" % t})
        p.stdin.close(); self.assertEqual(p.wait(20), 0)
        self.assertNotIn(gate.TOKEN_ENV, json.load(open(self.d + "/env")))
        text = open(os.path.join(self.data, "mcp", "audit", "rvt2027-a.jsonl")).read()
        self.assertNotIn(t, text)
        self.assertIn("[token]", text)

    def test_capabilities_both_ways(self):
        p = self.start(self.token())
        r = self.init(p)
        self.assertEqual(r["result"]["capabilities"], {"tools": {"listChanged": True}})
        self.assertEqual(self.seen()[0]["params"]["capabilities"], {})

    def test_list_is_filtered_and_call_never_reaches_the_server(self):
        p = self.start(self.token(), tools="query_model move_elements a_new_tool")
        self.init(p)
        self.send(p, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {"cursor": "c"}})
        r = self.recv(p)
        self.assertEqual([t["name"] for t in r["result"]["tools"]], ["query_model"])
        self.assertEqual(r["result"]["nextCursor"], "more")
        r = self.call(p, 3, "move_elements")
        self.assertTrue(r["result"]["isError"])
        self.assertIn("read tier", r["result"]["content"][0]["text"])
        self.assertNotIn("tools/call", [m.get("method") for m in self.seen()])
        self.assertIn("result", self.call(p, 4, "query_model"))
        p.stdin.close(); p.wait(20)
        ev = self.audit()
        self.assertEqual([e["event"] for e in ev], ["session_start", "client", "hidden", "call", "call", "result", "session_end"])
        self.assertEqual(ev[2]["tool"], "a_new_tool")
        self.assertEqual((ev[3]["decision"], ev[3]["reason"]), ("deny", "tier"))
        self.assertEqual(ev[4]["decision"], "allow")
        self.assertEqual((ev[6]["calls"], ev[6]["denied"]), (2, 1))

    def test_bad_messages_stop_here(self):
        p = self.start(self.token())
        self.init(p)
        n = len(self.seen())
        rc = [(b"not json", -32700), (b"[]", -32600), (b'{"jsonrpc":"2.0","id":true,"method":"ping"}', -32600),
              (b'{"jsonrpc":"2.0","id":null,"method":"ping"}', -32600), (b'{"jsonrpc":"2.0","id":1.5,"method":"ping"}', -32600),
              (b'{"jsonrpc":"2.0","id":2,"method":"ping","result":{}}', -32600),
              (b'{"jsonrpc":"2.0","id":3,"method":"ping","params":[]}', -32600),
              (b'{"jsonrpc":"2.0","id":4,"method":"resources/list"}', -32601),
              (b'{"jsonrpc":"2.0","id":5,"method":"prompts/get"}', -32601), (b'{"jsonrpc":"2.0","id":1,"method":"ping"}', -32600)]
        for line, code in rc:
            self.send(p, line)
            self.assertEqual(self.recv(p)["error"]["code"], code, line)
        for i, name in enumerate((None, True, 3, [], {}, "")):
            self.send(p, {"jsonrpc": "2.0", "id": 100 + i, "method": "tools/call", "params": {"name": name}})
            self.assertEqual(self.recv(p)["error"]["code"], -32602)
        self.send(p, b'{"jsonrpc":"2.0","method":"notifications/unknown"}')
        self.send(p, b'{"jsonrpc":"2.0","id":777,"result":{}}')
        self.send(p, {"jsonrpc": "2.0", "id": 50, "method": "ping"})
        self.assertEqual(self.recv(p)["id"], 50)
        self.assertEqual([m.get("id") for m in self.seen()[n:]], [50])

    def test_string_and_number_ids_are_different(self):
        p = self.start(self.token())
        self.init(p)
        self.send(p, {"jsonrpc": "2.0", "id": "1", "method": "ping"})
        self.assertEqual(self.recv(p)["id"], "1")

    def test_server_requests(self):
        p = self.start(self.token(), mode="sampling")
        self.init(p)
        r = self.recv(p)   # the sampling request never reaches the client; ping does
        self.assertEqual((r["id"], r["method"]), (901, "ping"))
        self.send(p, {"jsonrpc": "2.0", "id": 901, "result": {}})
        self.send(p, {"jsonrpc": "2.0", "id": 2, "method": "ping"})
        self.assertEqual(self.recv(p)["id"], 2)
        seen = self.seen()
        self.assertTrue(any(m.get("id") == 900 and m["error"]["code"] == -32601 for m in seen))
        self.assertTrue(any(m.get("id") == 901 and "result" in m for m in seen))

    def test_noise_does_not_reach_the_client(self):
        p = self.start(self.token(), mode="noise")
        r = self.init(p)
        self.assertEqual(r["id"], 1)
        p.stdin.close(); p.wait(20)
        self.assertIn(b"not MCP", p.stderr.read())
        self.assertIn("server_noise", [e["event"] for e in self.audit()])

    def test_a_big_answer(self):
        p = self.start(self.token("write"), mode="big", tools="query_model")
        self.init(p)
        self.assertGreater(len(self.call(p, 2, "query_model")["result"]["content"][0]["text"]), 5 << 20 - 1)

    def test_no_log_no_call(self):
        p = self.start(self.token())
        self.init(p)
        path = os.path.join(self.data, "mcp", "audit", "rvt2027-a.jsonl")
        open(path, "a").write("half a line")
        r = self.call(p, 2, "query_model")
        self.assertIn("not made", r["result"]["content"][0]["text"])
        self.assertNotIn("tools/call", [m.get("method") for m in self.seen()])

    def test_no_log_no_session(self):
        t = self.token()
        d = os.path.join(self.data, "mcp", "audit")
        os.makedirs(d)
        open(os.path.join(d, "rvt2027-a.jsonl"), "w").write("half")
        p = self.start(t)
        self.assertEqual(p.wait(20), 1)
        self.assertFalse(os.path.exists(self.d + "/argv"))


class Lifecycle(World):
    def test_exit_code_and_eof(self):
        p = self.start(self.token(), env={"FAKE_RC": "7"})
        p.stdin.close()
        self.assertEqual(p.wait(20), 7)

    def test_child_exit_ends_the_gate_with_stdin_open(self):
        p = self.start(self.token())
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        kid = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
        os.kill(int(kid[0]), signal.SIGTERM)
        self.assertEqual(p.wait(20), 143)

    def test_term_is_passed_on_and_waited_for(self):
        p = self.start(self.token())
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        p.terminate()
        self.assertEqual(p.wait(20), 143)

    def test_a_server_stuck_after_eof_gets_term(self):
        gate_grace = gate.EOF_GRACE_S
        p = self.start(self.token(), mode="hang-after-eof")
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        t = time.time()
        p.stdin.close()
        self.assertEqual(p.wait(gate_grace + 10), 143)
        self.assertGreaterEqual(time.time() - t, gate_grace - 0.5)

    def test_gate_never_kills_a_launcher_that_ignores_term(self):
        p = self.start(self.token(), mode="ignore-term")
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        p.terminate()
        time.sleep(1)
        kids = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
        self.assertTrue(kids)
        p.stdin.close()
        self.assertEqual(p.wait(20), 0)

    def test_revoking_ends_a_quiet_session(self):
        p = self.start(self.token(name="n"))
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        rows = [r for r in gate.load_tokens(self.data) if r["name"] != "n"]
        gate.save_tokens(self.data, rows)
        self.assertEqual(p.wait(gate.WATCH_S + 8), 1)
        self.assertEqual(self.audit()[-1]["reason"], "revoked")

    def test_a_new_token_of_the_same_name_ends_the_session(self):
        p = self.start(self.token(name="n"))
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        self.token(name="n")
        self.assertEqual(p.wait(gate.WATCH_S + 8), 1)

    def test_damaged_tokens_end_the_session(self):
        p = self.start(self.token())
        self.assertTrue(self.wait_for(lambda: os.path.exists(self.d + "/env")))
        open(os.path.join(self.data, "mcp", "tokens.json"), "w").write("[")
        self.assertEqual(p.wait(gate.WATCH_S + 8), 1)

    def test_closed_client_stdout(self):
        p = self.start(self.token())
        p.stdout.close()
        self.send(p, {"jsonrpc": "2.0", "id": 1, "method": "bogus"})
        self.assertIn(p.wait(gate.EOF_GRACE_S + 10), (0, 143))


class Bundle(World):
    def args(self, bottle, server):
        return gate.parser().parse_args(["bundle", "--root", "/App Path/res", "--data", self.data, "--year", "2027",
                                         "--bottle", bottle, "--server", server, "--tier", "read", "--out-dir", self.d])

    def test_contents(self):
        for server in gate.TOOLS:
            a = self.args("rvt2027-a", server)
            with zipfile.ZipFile(__import__("io").BytesIO(gate.bundle_bytes(a))) as z:
                self.assertEqual(sorted(z.namelist()), ["manifest.json", "server/start.sh"])
                m = json.loads(z.read("manifest.json"))
                start = z.read("server/start.sh").decode()
            self.assertEqual(m["manifest_version"], "0.3")
            self.assertEqual(m["server"]["entry_point"], "server/start.sh")
            self.assertEqual(m["server"]["mcp_config"]["env"], {gate.TOKEN_ENV: "${user_config.token}"})
            self.assertTrue(m["user_config"]["token"]["sensitive"])
            self.assertEqual(m["compatibility"]["platforms"], ["darwin"])
            self.assertIn("exec '/App Path/res/revit' mcp 2027 rvt2027-a --server %s\n" % server, start)

    def test_two_bottles_two_identities(self):
        a, b = gate.manifest(self.args("rvt2027-a", "python")), gate.manifest(self.args("rvt2027-b", "python"))
        self.assertNotEqual(a["name"], b["name"])
        self.assertNotEqual(a["display_name"], b["display_name"])


if __name__ == "__main__":
    unittest.main()
