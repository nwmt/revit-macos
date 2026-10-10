#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Minimal stdlib Chrome DevTools Protocol client for inspecting the embedded AdSSO
browser (QtWebEngine 5.9) under Wine. Needs QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9222 in the bottle.

  tools/cdp.py list                        -- tabs (url, title)
  tools/cdp.py watch [seconds] [--reload]  -- subscribe to console/network/exceptions of the first tab
  tools/cdp.py eval '<js>'                 -- evaluate an expression in the page
"""
import base64, json, os, socket, struct, sys, time, urllib.request

HOST, PORT = "127.0.0.1", 9222


def targets():
    with urllib.request.urlopen(f"http://{HOST}:{PORT}/json", timeout=5) as r:
        return [t for t in json.load(r) if t.get("type") == "page"]


class WS:
    def __init__(self, url):
        path = url.split(f":{PORT}", 1)[1]
        self.s = socket.create_connection((HOST, PORT), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.s.recv(4096)
        if b" 101 " not in resp.split(b"\r\n")[0]:
            raise RuntimeError(resp.decode(errors="replace"))
        self.buf = resp.split(b"\r\n\r\n", 1)[1]
        self.next_id = 0

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, method, **params):
        self.next_id += 1
        payload = json.dumps({"id": self.next_id, "method": method, "params": params}).encode()
        hdr = bytes([0x81])
        n = len(payload)
        hdr += bytes([0x80 | n]) if n < 126 else (bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        mask = os.urandom(4)
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        return self.next_id

    def recv(self, timeout):
        self.s.settimeout(timeout)
        data = b""
        while True:
            b0, b1 = self._recv_exact(2)
            n = b1 & 0x7F
            if n == 126: n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127: n = struct.unpack(">Q", self._recv_exact(8))[0]
            data += self._recv_exact(n)
            if b0 & 0x80:
                return json.loads(data) if (b0 & 0x0F) in (1, 0) else None

    def call(self, method, timeout=10, **params):
        i = self.send(method, **params)
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv(end - time.time())
            if m and m.get("id") == i:
                return m
        raise TimeoutError(method)


def short(s, n=220):
    s = str(s).replace("\n", " ")
    return s if len(s) <= n else s[:n] + "…"


def watch(seconds, reload):
    t = targets()
    if not t:
        print("no tabs"); return
    page = t[0]
    print("tab:", short(page.get("url")), "|", page.get("title"))
    ws = WS(page["webSocketDebuggerUrl"])
    for dom in ("Runtime", "Log", "Network", "Page", "Security"):
        try: ws.call(f"{dom}.enable")
        except Exception as e: print(f"{dom}.enable: {e}")
    state = ws.call("Runtime.evaluate", expression="JSON.stringify({u:location.href,r:document.readyState,t:document.title,b:(document.body&&document.body.innerText||'').slice(0,300)})", returnByValue=True)
    print("page:", short(state.get("result", {}).get("result", {}).get("value"), 500))
    if reload:
        ws.send("Page.reload", ignoreCache=True); print("→ Page.reload")
    reqs = {}
    end = time.time() + seconds
    while time.time() < end:
        try: m = ws.recv(end - time.time())
        except (socket.timeout, TimeoutError): break
        if not m or "method" not in m: continue
        meth, p = m["method"], m.get("params", {})
        if meth == "Runtime.consoleAPICalled":
            args = " ".join(short(a.get("value", a.get("description", a.get("type"))), 150) for a in p.get("args", []))
            print(f"console.{p.get('type')}: {args}")
        elif meth == "Runtime.exceptionThrown":
            d = p.get("exceptionDetails", {})
            print("EXCEPTION:", short(d.get("exception", {}).get("description") or d.get("text"), 400), "@", short(d.get("url"), 120), d.get("lineNumber"))
        elif meth == "Log.entryAdded":
            e = p.get("entry", {})
            print(f"log.{e.get('level')} [{e.get('source')}]: {short(e.get('text'), 300)} {short(e.get('url', ''), 120)}")
        elif meth == "Network.requestWillBeSent":
            reqs[p["requestId"]] = p["request"]["url"]
        elif meth == "Network.responseReceived":
            r = p["response"]
            if r.get("status", 0) >= 400:
                print(f"HTTP {r.get('status')}: {short(r.get('url'), 200)}")
        elif meth == "Network.loadingFailed":
            print(f"NET FAIL {p.get('errorText')} {'(blocked: ' + str(p.get('blockedReason')) + ')' if p.get('blockedReason') else ''}: {short(reqs.get(p['requestId'], '?'), 200)}")
        elif meth == "Page.frameNavigated" and not p.get("frame", {}).get("parentId"):
            print("NAVIGATED:", short(p["frame"].get("url"), 200))
        elif meth == "Security.securityStateChanged" and p.get("securityState") not in ("secure", "neutral"):
            print("SECURITY:", p.get("securityState"), short(p.get("summary", ""), 200))
    state = ws.call("Runtime.evaluate", expression="JSON.stringify({u:location.href,r:document.readyState,t:document.title,ua:navigator.userAgent,b:(document.body&&document.body.innerText||'').slice(0,300)})", returnByValue=True)
    print("page at end:", short(state.get("result", {}).get("result", {}).get("value"), 700))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        for t in targets():
            print(t.get("id"), "|", short(t.get("url"), 200), "|", t.get("title"))
    elif cmd == "watch":
        secs = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2][0].isdigit() else 30
        watch(secs, "--reload" in sys.argv)
    elif cmd == "eval":
        t = targets()[0]
        ws = WS(t["webSocketDebuggerUrl"])
        print(json.dumps(ws.call("Runtime.evaluate", expression=sys.argv[2], returnByValue=True).get("result"), ensure_ascii=False, indent=1)[:4000])


if __name__ == "__main__":
    main()
