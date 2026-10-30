# SPDX-License-Identifier: MIT
"""The gate between an MCP client and ./revit mcp's server: who may connect, what it may use, and a log of what it did.

  mcp_gate.py serve revit-macos-mcp-gate <bottle real path> --root R --data D --year Y --bottle N --server S --policy P
  mcp_gate.py token-create --root R --data D --year Y --bottle N --server S --tier T [--name N] [--experimental]
  mcp_gate.py token-list --data D
  mcp_gate.py token-revoke --data D --name N
  mcp_gate.py bundle --root R --data D --year Y --bottle N --server S --tier T --out-dir O [--experimental]

serve reads the client's token from REVIT_MCP_TOKEN, never from arguments, and starts scripts/mcp-launch.sh with stdin and
stdout on pipes; that script keeps the lock and ends its own processes, so nothing here ever sends it KILL. The first two
arguments of serve mark the process (tools/leftovers.py finds a gate whose client is gone). Stdout is the client's.

A token is a grant: bottle, server, tier, revocable. It is not a wall: a process of this macOS account can edit the token
file or start Wine itself. docs/mcp.md says so. Tiers are read < write < code; below code a tool that is in no list here
is hidden and refused. Python 3.9 and the standard library only: this runs on the Python of the Command Line Tools.
"""
import argparse
import contextlib
import fcntl
import hashlib
import hmac
import io
import json
import os
import queue
import re
import secrets
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
import zipfile

MARKER = "revit-macos-mcp-gate"
TIERS = ("read", "write", "code")
TOKEN_ENV = "REVIT_MCP_TOKEN"
WATCH_S = 2          # how often a live session looks whether its token is still there
EOF_GRACE_S = 5      # after the client is gone, how long the server may take to leave by itself before TERM
ARGS_KEPT = 4096     # characters of a call's arguments kept in the log
DRAIN_S = 30         # after the server ended, how long a slow client gets to take what is already here
QUEUED_MAX = 256 << 20   # bytes waiting for a side that stopped reading; beyond it the session ends
AUDIT_MAX = 10 << 20
AUDIT_KEEP = 3

# what each tier adds; pyRevit has no write tier: its changes are code, and Autodesk's have no code unless Experimental
TOOLS = {
    "autodesk": {
        "read": frozenset("export_views get_active_context get_element_data get_running_revit_instances open_view "
                          "query_model review_changes select_elements show_elements".split()),
        "write": frozenset("modify_element_parameters move_elements rotate_elements".split()),
    },
    "pyrevit": {
        "read": frozenset("get_skill list_skills list_revit_instances get_context inspect_elements lookup_revit_api "
                          "lookup_pyrevit_api show_elements navigate_revit_link capture_view get_run "
                          "list_automation".split()),
        "write": frozenset(),
        "code": frozenset("run_query run_modify run_automation".split()),
    },
    "python": {
        "read": frozenset("get_revit_status get_revit_model_info get_current_view_info get_current_view_elements "
                          "get_revit_view list_levels list_revit_views list_families list_family_categories "
                          "list_category_parameters list_revit_installations".split()),
        "write": frozenset("clear_colors close_document color_splash launch_revit open_document place_family "
                           "save_document sync_with_central".split()),
        "code": frozenset(("execute_revit_code",)),
    },
}
CLIENT_REQUESTS = frozenset(("initialize", "ping", "tools/list", "tools/call", "logging/setLevel"))
CLIENT_NOTES = frozenset(("notifications/initialized", "notifications/cancelled"))
SERVER_REQUESTS = frozenset(("ping",))
SERVER_NOTES = frozenset(("notifications/tools/list_changed", "notifications/progress", "notifications/message",
                          "notifications/cancelled"))
SERVER_CAPS = ("tools", "logging")   # all a server may declare through the gate; a client declares nothing


class GateError(Exception):
    """A reason for the person, one line."""


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def tool_allowed(server, tier, name):
    if tier == "code":
        return True
    t = TOOLS[server]
    return name in t["read"] or (tier == "write" and name in t["write"])


def tier_problem(server, tier, experimental):
    """Why this server cannot have this tier, or None."""
    if tier not in TIERS:
        return "Unknown tier: %s. Known: read, write, code" % tier
    if server == "pyrevit" and tier == "write":
        return "pyRevit's agent changes the model by running code: use --tier code."
    if server == "autodesk" and tier == "code" and not experimental:
        return "Autodesk's Write-Tools have no code tier: use --tier write."
    return None


# ---- tokens ----
def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def mcp_dir(data):
    return private_dir(os.path.join(data, "mcp"))


@contextlib.contextmanager
def locked(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def load_tokens(data):
    """The records; GateError when the file cannot be trusted. Read fresh each time: it is small."""
    try:
        with open(os.path.join(data, "mcp", "tokens.json"), encoding="utf-8") as f:
            rows = json.load(f)
    except FileNotFoundError:
        return []
    except (OSError, ValueError) as e:
        raise GateError("Cannot read the MCP tokens: %s" % e)
    if not isinstance(rows, list) or not all(isinstance(r, dict) and isinstance(r.get("sha256"), str)
                                             and re.fullmatch(r"[0-9a-f]{64}", r["sha256"]) for r in rows):
        raise GateError("The file of MCP tokens is damaged.")
    return rows


def save_tokens(data, rows):
    d = mcp_dir(data)
    tmp = os.path.join(d, "tokens.json.tmp.%d" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1)
    os.replace(tmp, os.path.join(d, "tokens.json"))


def token_sha(value):
    return hashlib.sha256(value.encode("utf-8", "surrogateescape")).hexdigest()


def create_token(data, name, year, bottle, server, tier):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", name):
        raise GateError("A token name is letters, digits, dot, dash and underscore, up to 64.")
    value = secrets.token_urlsafe(32)
    with locked(os.path.join(mcp_dir(data), "tokens.lock")):
        rows = [r for r in load_tokens(data) if r.get("name") != name]
        rows.append({"name": name, "sha256": token_sha(value), "tier": tier, "bottle": bottle, "year": year,
                     "server": server, "created": now()})
        save_tokens(data, rows)
    return value


def find_token(rows, sha, bottle, server):
    for r in rows:
        if hmac.compare_digest(r["sha256"], sha) and r.get("bottle") == bottle and r.get("server") == server \
                and r.get("tier") in TIERS:
            return r
    return None


def need_terminal():
    if not os.isatty(0):
        raise GateError("Run this in Terminal: a token is shown once, to you.")


def issue_hint(year, bottle, server):
    return "./revit mcp token %s %s --server %s" % (year, bottle, server)


# ---- the log ----
class Audit:
    """One JSONL file per bottle. Every write takes the lock, opens the current file, rotates when due, writes the whole
    line and rolls back a partial one, so two gates never tear a line and no write lands in a rotated-away file."""

    def __init__(self, data, bottle, secret="", max_bytes=AUDIT_MAX):
        self.dir = private_dir(os.path.join(mcp_dir(data), "audit"))
        self.path = os.path.join(self.dir, bottle + ".jsonl")
        self.lock = os.path.join(self.dir, bottle + ".lock")
        self.secret, self.max_bytes = secret, max_bytes

    def rotate(self):
        with contextlib.suppress(FileNotFoundError):
            os.unlink("%s.%d" % (self.path, AUDIT_KEEP))
        for i in range(AUDIT_KEEP - 1, 0, -1):
            with contextlib.suppress(FileNotFoundError):
                os.rename("%s.%d" % (self.path, i), "%s.%d" % (self.path, i + 1))
        os.rename(self.path, self.path + ".1")

    def write(self, record):
        """Raises OSError when the line is not in the file whole."""
        text = json.dumps(record, ensure_ascii=False, sort_keys=True)
        if self.secret:
            text = text.replace(self.secret, "[token]")
        line = (text + "\n").encode("utf-8", "replace")
        with locked(self.lock):
            with contextlib.suppress(FileNotFoundError):
                if os.path.getsize(self.path) + len(line) > self.max_bytes:
                    self.rotate()
            fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                size = os.fstat(fd).st_size
                if size and os.pread(fd, 1, size - 1) != b"\n":
                    raise OSError("the MCP log ends in a broken line: %s" % self.path)
                try:
                    if os.write(fd, line) != len(line):
                        raise OSError("short write to the MCP log")
                except OSError:
                    os.ftruncate(fd, size)   # if this fails too, the check above stops every later write
                    raise
            finally:
                os.close(fd)


# ---- messages ----
def good_id(i):
    return isinstance(i, str) or (isinstance(i, int) and not isinstance(i, bool))


def kind_of(m):
    """request, notification, success, error, or None: not a message of this protocol."""
    if not isinstance(m, dict) or m.get("jsonrpc") != "2.0":
        return None
    if "method" in m:
        if not isinstance(m["method"], str) or "result" in m or "error" in m:
            return None
        if "params" in m and not isinstance(m["params"], dict):
            return None
        if "id" not in m:
            return "notification"
        return "request" if good_id(m["id"]) else None
    if "id" not in m or not good_id(m["id"]) or ("result" in m) == ("error" in m):
        return None
    if "error" in m:
        return "error" if isinstance(m["error"], dict) else None
    return "success"


def key_of(i):
    return (type(i).__name__, i)


def dumps(m):
    return (json.dumps(m, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8", "surrogatepass")


def error_reply(i, code, text):
    return {"jsonrpc": "2.0", "id": i, "error": {"code": code, "message": text}}


class Session:
    def __init__(self, a, audit, sha, record, child, session):
        self.a, self.audit, self.sha, self.child, self.id = a, audit, sha, child, session
        self.tier, self.server = record["tier"], a.server
        self.state = threading.Lock()
        self.to_client, self.to_child = queue.Queue(), queue.Queue()   # each drained by its own writer: a pipe that is
        # full never stops a pump, and ending never waits for a write
        self.waiting = {}            # our client's open requests: key -> (method, tool, started)
        self.seen_client, self.seen_server, self.server_open = set(), set(), set()
        self.hidden = set()
        self.queued = 0
        self.calls = self.denied = 0
        self.ending, self.gone = None, False

    # ---- output ----
    def log(self, event, **fields):
        fields.update(ts=now(), session=self.id, event=event)
        self.audit.write(fields)

    def log_soft(self, event, **fields):
        try:
            self.log(event, **fields)
        except OSError as e:
            sys.stderr.write("MCP log: %s\n" % e)

    def enqueue(self, q, data):
        with self.state:
            self.queued += len(data)
            over = self.queued > QUEUED_MAX
        if over:
            self.end("overflow")
        else:
            q.put(data)

    def written(self, data):
        with self.state:
            self.queued -= len(data)

    def send_client(self, data):
        self.enqueue(self.to_client, data)

    def send_child(self, data):
        self.enqueue(self.to_child, data)

    def write_client(self):
        out = sys.stdout.buffer
        for data in iter(self.to_client.get, None):
            if self.ending:   # nothing more goes out of a session that was revoked
                return
            try:
                out.write(data)
                out.flush()
            except (OSError, ValueError):
                self.client_gone()
                return
            self.written(data)

    def write_child(self):
        f = self.child.stdin
        try:
            for data in iter(self.to_child.get, None):
                if self.ending:   # a call still queued when its token was revoked is not delivered
                    break
                f.write(data)
                f.flush()
                self.written(data)
        except (OSError, ValueError):
            pass
        with contextlib.suppress(OSError, ValueError):
            f.close()

    def term_child(self):
        if self.child.poll() is None:
            with contextlib.suppress(OSError):
                self.child.terminate()

    # ---- ending; the launcher does the rest and the main thread waits for it ----
    def client_gone(self):
        with self.state:
            if self.gone:
                return
            self.gone = True
        self.to_child.put(None)
        t = threading.Timer(EOF_GRACE_S, self.term_child)
        t.daemon = True
        t.start()

    def end(self, reason):
        with self.state:
            if self.ending:
                return
            self.ending = reason
        self.term_child()
        self.to_child.put(None)

    def token_good(self):
        try:
            return find_token(load_tokens(self.a.data), self.sha, self.a.bottle, self.server) is not None
        except GateError:
            return False

    def watch(self):
        while not self.ending:
            time.sleep(WATCH_S)
            if not self.token_good():
                self.end("revoked")

    # ---- from the client ----
    def from_client(self, line):
        if not line.strip():
            return
        try:
            m = json.loads(line)
        except (ValueError, RecursionError):
            return self.send_client(dumps(error_reply(None, -32700, "Not JSON")))
        kind = kind_of(m)
        if kind is None:
            return self.send_client(dumps(error_reply(None, -32600, "Not a valid message")))
        if kind == "notification":
            if m["method"] in CLIENT_NOTES:
                self.send_child(line)
            return None
        if kind in ("success", "error"):
            with self.state:
                known = key_of(m["id"]) in self.server_open
                self.server_open.discard(key_of(m["id"]))
            if known:
                self.send_child(line)
            return None
        return self.client_request(m, line)

    def client_request(self, m, line):
        i, method, k = m["id"], m["method"], key_of(m["id"])
        with self.state:
            again = k in self.seen_client
            self.seen_client.add(k)
        if again:
            return self.send_client(dumps(error_reply(i, -32600, "This id was already used")))
        if self.ending:
            return self.send_client(dumps(error_reply(i, -32000, "This connection has ended: its token was revoked")))
        if method not in CLIENT_REQUESTS:
            return self.send_client(dumps(error_reply(i, -32601, "Method not available: %s" % method)))
        tool = None
        if method == "initialize":
            params = m.setdefault("params", {})
            info = params.get("clientInfo")
            info = info if isinstance(info, dict) else {}
            self.log_soft("client", name=str(info.get("name"))[:100], version=str(info.get("version"))[:100])
            params["capabilities"] = {}
            line = dumps(m)
        elif method == "tools/call":
            tool = self.tool_call(m)
            if tool is None:
                return None
        with self.state:
            self.waiting[k] = (method, tool, time.monotonic())
        self.send_child(line)
        return None

    def tool_call(self, m):
        """The tool's name when the call may go on; otherwise it is answered here and None comes back."""
        i, params = m["id"], m.get("params", {})
        name, args = params.get("name"), params.get("arguments")
        if not isinstance(name, str) or not name:
            self.denied += 1
            self.send_client(dumps(error_reply(i, -32602, "A tool call needs a tool name")))
            return None
        raw = json.dumps(args, ensure_ascii=False, sort_keys=True)
        rec = dict(id=i, tool=name, args=raw[:ARGS_KEPT], args_bytes=len(raw),
                   args_sha256=hashlib.sha256(raw.encode("utf-8", "surrogatepass")).hexdigest())
        self.calls += 1
        reason = None
        if not self.token_good():
            reason = "revoked"
            self.end(reason)
        elif not tool_allowed(self.server, self.tier, name):
            reason = "tier"
        try:
            self.log("call", decision="deny" if reason else "allow", reason=reason, **rec)
        except OSError as e:
            sys.stderr.write("MCP log: %s\n" % e)
            reason = "log"
        if not reason:
            return name
        self.denied += 1
        text = {"tier": "This connection may not use %s: its token is for the %s tier. The person who runs Revit can "
                        "issue a token with a higher tier (docs/mcp.md)." % (name, self.tier),
                "log": "The call was not made: the log of MCP calls cannot be written.",
                "revoked": "The call was not made: the token of this connection was revoked."}[reason]
        self.send_client(dumps({"jsonrpc": "2.0", "id": i,
                                "result": {"isError": True, "content": [{"type": "text", "text": text}]}}))
        return None

    # ---- from the server ----
    def noise(self, line):
        sys.stderr.write("MCP server: a line that is not MCP was dropped (%d bytes)\n" % len(line))
        self.log_soft("server_noise", bytes=len(line))

    def from_server(self, line):
        if not line.strip():
            return
        try:
            m = json.loads(line)
        except (ValueError, RecursionError):
            return self.noise(line)
        kind = kind_of(m)
        if kind is None:
            return self.noise(line)
        if kind == "notification":
            if m["method"] in SERVER_NOTES:
                self.send_client(line)
            return None
        if kind == "request":
            return self.server_request(m, line)
        with self.state:
            open_call = self.waiting.pop(key_of(m["id"]), None)
        if open_call is None:
            return self.noise(line)
        method, tool, started = open_call
        if kind == "success" and method == "initialize" and isinstance(m["result"], dict):
            caps = m["result"].get("capabilities")
            caps = caps if isinstance(caps, dict) else {}
            m["result"]["capabilities"] = {c: caps[c] for c in SERVER_CAPS if c in caps}
            line = dumps(m)
        elif kind == "success" and method == "tools/list":
            line = self.filter_tools(m)
        elif method == "tools/call":
            res = m.get("result")
            self.log_soft("result", id=m["id"], tool=tool, ms=int((time.monotonic() - started) * 1000), bytes=len(line),
                          is_error=kind == "error" or (isinstance(res, dict) and res.get("isError") is True))
        return self.send_client(line)

    def filter_tools(self, m):
        res = m["result"] if isinstance(m["result"], dict) else {}
        tools = res.get("tools") if isinstance(res.get("tools"), list) else []
        kept = []
        for t in tools:
            name = t.get("name") if isinstance(t, dict) else None
            if isinstance(name, str) and tool_allowed(self.server, self.tier, name):
                kept.append(t)
            elif isinstance(name, str) and not any(name in s for s in TOOLS[self.server].values()) \
                    and name not in self.hidden:
                self.hidden.add(name)
                self.log_soft("hidden", tool=name)
        res["tools"] = kept
        m["result"] = res
        return dumps(m)

    def server_request(self, m, line):
        k = key_of(m["id"])
        with self.state:
            again = k in self.seen_server
            self.seen_server.add(k)
            ok = not again and m["method"] in SERVER_REQUESTS
            if ok:
                self.server_open.add(k)
        if ok:
            return self.send_client(line)
        return self.send_child(dumps(error_reply(m["id"], -32600 if again else -32601, "Not available")))

    # ---- the two directions ----
    def pump_client(self):
        for line in sys.stdin.buffer:
            self.from_client(line)
        self.client_gone()

    def pump_server(self):
        for line in self.child.stdout:
            self.from_server(line)


def serve(a):
    secret = os.environ.pop(TOKEN_ENV, "")
    hint = "This connection needs a token. In Terminal: %s" % issue_hint(a.year, a.bottle, a.server)
    try:
        rows = load_tokens(a.data)
    except GateError as e:
        raise GateError("%s %s" % (e, hint))
    sha = token_sha(secret)
    record = find_token(rows, sha, a.bottle, a.server) if secret else None
    if record is None:
        raise GateError(hint if not secret else "This token is not valid for %s and the %s server. %s"
                        % (a.bottle, a.server, hint[len("This connection needs a token. "):]))
    audit = Audit(a.data, a.bottle, secret)
    write = "0" if record["tier"] == "read" else "1"
    script = os.path.join(a.root, "scripts", "mcp-launch.sh")
    session = uuid.uuid4().hex
    try:
        audit.write({"ts": now(), "session": session, "event": "session_start", "token": record.get("name"),
                     "tier": record["tier"], "bottle": a.bottle, "year": a.year, "server": a.server,
                     "policy": a.policy or None})
    except OSError as e:
        raise GateError("Cannot write the log of MCP calls, so no connection: %s" % e)
    if a.server == "pyrevit" and record["tier"] == "code" and a.policy == "auto":
        sys.stderr.write("pyRevit applies changes without asking (policy auto). Choose Ask in pyRevit's settings.\n")
    early = []   # a signal before the child exists goes to it as soon as it does
    child = None
    def forward(n, _frame):
        if child is None:
            early.append(n)
        elif child.poll() is None:
            child.send_signal(n)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, forward)
    child = subprocess.Popen([script, a.year, a.bottle, write, a.server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             start_new_session=True)
    for n in early:
        forward(n, None)
    s = Session(a, audit, sha, record, child, session)
    reader = threading.Thread(target=s.pump_server, daemon=True)
    client_writer = threading.Thread(target=s.write_client, daemon=True)
    for t in (threading.Thread(target=s.pump_client, daemon=True), reader, client_writer,
              threading.Thread(target=s.write_child, daemon=True), threading.Thread(target=s.watch, daemon=True)):
        t.start()
    code = child.wait()
    reader.join(3)   # a descendant may keep the pipe open
    s.to_client.put(None)
    drain_until = time.monotonic() + DRAIN_S
    while client_writer.is_alive() and not s.ending and not s.gone and time.monotonic() < drain_until:
        client_writer.join(0.2)   # a revoked session owes the client nothing more
    code = code if code >= 0 else 128 - code
    s.log_soft("session_end", code=code, calls=s.calls, denied=s.denied, reason=s.ending or ("client" if s.gone else "server"))
    sys.stderr.flush()
    os._exit(1 if s.ending else code)


# ---- commands ----
def show_token(value, a, name):
    args = "%s %s --server %s" % (a.year, a.bottle, a.server)
    print("Token %s (%s, tier %s). It is shown once:\n\n  %s\n" % (name, a.bottle, a.tier, value))
    return args


def token_create(a):
    need_terminal()
    why = tier_problem(a.server, a.tier, a.experimental)
    if why:
        raise GateError(why)
    name = a.name or "%s-%s-%s" % (a.bottle, a.server, a.tier)
    value = create_token(a.data, name, a.year, a.bottle, a.server, a.tier)
    args = show_token(value, a, name)
    print("Claude Code:\n\n  claude mcp add revit-%s -e %s=%s -- %s mcp %s\n"
          % (a.year, TOKEN_ENV, value, shlex.quote(os.path.join(a.root, "revit")), args))


def token_list(a):
    rows = load_tokens(a.data)
    if not rows:
        print("No MCP tokens.")
    for r in rows:
        print("%-40s %-12s %-9s %-6s %s" % (r.get("name"), r.get("bottle"), r.get("server"), r.get("tier"), r.get("created")))


def token_revoke(a):
    with locked(os.path.join(mcp_dir(a.data), "tokens.lock")):
        rows = load_tokens(a.data)
        kept = [r for r in rows if r.get("name") != a.name]
        if len(kept) == len(rows):
            raise GateError("There is no MCP token %s." % a.name)
        save_tokens(a.data, kept)
    print("Token %s is revoked. A connection using it ends within %d seconds." % (a.name, WATCH_S))


def manifest(a):
    return {
        "manifest_version": "0.3",
        "name": "revit-%s-%s" % (a.bottle.lower(), a.server),
        "display_name": "Revit %s, %s (%s)" % (a.year, a.bottle, a.server),
        "version": "1.0.0",
        "description": "Connects Claude to Revit %s in bottle %s on this Mac." % (a.year, a.bottle),
        "author": {"name": "revit-macos"},
        "server": {"type": "binary", "entry_point": "server/start.sh",
                   "mcp_config": {"command": "/bin/sh", "args": ["${__dirname}/server/start.sh"],
                                  "env": {TOKEN_ENV: "${user_config.token}"}}},
        "user_config": {"token": {"type": "string", "title": "Access token", "sensitive": True, "required": True,
                                  "description": "The token ./revit mcp bundle printed."}},
        "compatibility": {"platforms": ["darwin"]},
    }


def bundle_bytes(a):
    start = "#!/bin/sh\nexec %s mcp %s %s --server %s\n" % (
        shlex.quote(os.path.join(a.root, "revit")), a.year, shlex.quote(a.bottle), a.server)
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest(a), indent=2) + "\n")
        z.writestr("server/start.sh", start)
    return out.getvalue()


def bundle(a):
    need_terminal()
    why = tier_problem(a.server, a.tier, a.experimental)
    if why:
        raise GateError(why)
    body = bundle_bytes(a)
    path = os.path.join(a.out_dir, "revit-%s-%s.mcpb" % (a.bottle, a.server))
    name = "claude-desktop-%s-%s" % (a.bottle, a.server)
    os.makedirs(a.out_dir, exist_ok=True)
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "wb") as f:
        f.write(body)
    os.replace(tmp, path)
    show_token(create_token(a.data, name, a.year, a.bottle, a.server, a.tier), a, name)
    print("Claude Desktop: Settings → Extensions → Advanced settings → Install Extension, choose\n\n  %s\n\n"
          "and paste the token when it asks. Claude Desktop keeps it in your Keychain." % path)


def parser():
    p = argparse.ArgumentParser(description="The gate of ./revit mcp")
    sub = p.add_subparsers(dest="cmd", required=True)
    def common(c, root=True, target=True):
        c.add_argument("--data", required=True)
        if root:
            c.add_argument("--root", required=True)
        if target:
            c.add_argument("--year", required=True)
            c.add_argument("--bottle", required=True)
            c.add_argument("--server", required=True, choices=sorted(TOOLS))
    c = sub.add_parser("serve")
    c.add_argument("marker")
    c.add_argument("bottle_path")
    common(c)
    c.add_argument("--policy", default="")
    c = sub.add_parser("token-create")
    common(c)
    c.add_argument("--tier", default="read")
    c.add_argument("--name", default="")
    c.add_argument("--experimental", action="store_true")
    c = sub.add_parser("bundle")
    common(c)
    c.add_argument("--tier", default="read")
    c.add_argument("--out-dir", required=True)
    c.add_argument("--experimental", action="store_true")
    common(sub.add_parser("token-list"), root=False, target=False)
    c = sub.add_parser("token-revoke")
    common(c, root=False, target=False)
    c.add_argument("--name", required=True)
    return p


def main(argv):
    a = parser().parse_args(argv)
    run = {"serve": serve, "token-create": token_create, "token-list": token_list, "token-revoke": token_revoke,
           "bundle": bundle}[a.cmd]
    try:
        run(a)
    except GateError as e:
        sys.stderr.write("%s\n" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
