# The Mac side of the MCP server for Revit (Python), add-in python-mcp: the pinned upstream commit, its folder under
# the data folder, the Python it runs on (the one python-build-standalone the app ships, app/tools.sh) and its venv.
# Sourced after common.sh. Functions that can fail print the reason on stdout and return 1.
PYMCP_COMMIT=6ca46b3ea96a8f7cce9894cf865d8f19ca2c549d

PYREVIT48_SERVER_SHA=6a1e0903edfcc69005813da00934ce7a7da06bd89abd4f3b294f3e1ae569f911   # routes/server/server.py of 4.8.12
PYMCP_EXT_REL="drive_c/users/crossover/AppData/Roaming/pyRevit/Extensions/revit-mcp-python.extension"
PYMCP_LOCAL_REL="drive_c/users/crossover/AppData/Local/RevitMCPPython"   # the extension's pairing and startup error

pymcp_dir() { echo "$DATA/mcp/python-mcp/$PYMCP_COMMIT"; }   # venv/ and src/ (the patched upstream sources)
pymcp_venv_python() { echo "$(pymcp_dir)/venv/bin/python3"; }

pymcp_python() { # the python3 to build the venv from: the app's own, or in a clone the same pinned build, downloaded once
  # into $DATA/mcp/python-<version> (sha256 from app/tools.sh; in a clone $DATA is the repo, whose tools/ is source).
  # One Python version, one file of hashes (tools/python-mcp-requirements.txt); the Mac's python3 is often 3.9 (the CLT)
  local d p tmp
  if [ "${REVIT_BUNDLED:-}" = 1 ]; then
    p="${APP_RES:-}/python/bin/python3"; [ -x "$p" ] && { echo "$p"; return 0; }
    echo "the app has no Python at $p"; return 1
  fi
  ( . "$ROOT/app/tools.sh"
    d="$DATA/mcp/python-$PYTHON_VERSION"; p="$d/bin/python3"
    [ -x "$p" ] && { echo "$p"; exit 0; }
    tmp="$DATA/mcp/.python-$PYTHON_VERSION.$$"; rm -rf "$tmp"; mkdir -p "$tmp" || { echo "cannot write $DATA/mcp"; exit 1; }
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/python.tar.gz" "$PYTHON_URL" >&2 || { echo "the Python download failed: $PYTHON_URL"; exit 1; }
    [ "$(shasum -a 256 "$tmp/python.tar.gz" | cut -d' ' -f1)" = "$PYTHON_SHA256" ] \
      || { echo "the Python download does not match PYTHON_SHA256 in app/tools.sh"; exit 1; }
    tar xzf "$tmp/python.tar.gz" -C "$tmp" && [ -x "$tmp/python/bin/python3" ] || { echo "no python/bin/python3 in $PYTHON_URL"; exit 1; }
    rm -rf "$d" && mv "$tmp/python" "$d" || { echo "cannot write $d"; exit 1; }
    echo "$p" )
}

pymcp_venv_ensure() { # $(pymcp_dir)/venv with the pinned packages; rebuilt only when the requirements file changed
  local py v req sha out
  py="$(pymcp_python)" || { echo "$py"; return 1; }
  v="$(pymcp_dir)/venv"; req="$ROOT/tools/python-mcp-requirements.txt"; sha="$(shasum -a 256 "$req" | cut -d' ' -f1)"
  [ -x "$v/bin/python3" ] && [ "$(cat "$v/.req-sha" 2>/dev/null)" = "$sha" ] && return 0
  mkdir -p "$(dirname "$v")" && rm -rf "$v.new" || { echo "cannot write $(dirname "$v")"; return 1; }
  out="$("$py" -m venv "$v.new" 2>&1)" || { rm -rf "$v.new"; echo "cannot make the venv: $(tail -1 <<<"$out")"; return 1; }
  out="$("$v.new/bin/python3" -m pip install -q --disable-pip-version-check --require-hashes --no-deps -r "$req" 2>&1)" \
    || { rm -rf "$v.new"; echo "the Python packages could not be installed: $(tail -1 <<<"$out")"; return 1; }
  echo "$sha" > "$v.new/.req-sha" && rm -rf "$v" && mv "$v.new" "$v" || { echo "cannot write $v"; return 1; }
}

pymcp_server_py() { echo "$B/$PYREVIT_CLONE_REL/pyrevitlib/pyrevit/routes/server/server.py"; }   # pyRevit 4.8's Routes
pymcp_server_state() { # $1 = server.py: original (pyRevit 4.8.12 as installed), patched (ours applied) or foreign
  [ -f "$1" ] || { echo foreign; return 0; }
  if [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$PYREVIT48_SERVER_SHA" ]; then echo original
  elif patch --binary -s -f -R --dry-run "$1" "$ROOT/tools/patches/pyrevit48/server.py.patch" >/dev/null 2>&1; then echo patched
  else echo foreign; fi
}

PYMCP_DPAPI_WIN='C:\ProgramData\revit-macos\dpapi\dpapi.exe'
dpapi_ensure() { # our dpapi.exe in the bottle, equal to $(shim_dir)/dpapi/dpapi.exe afterwards: written only when
  # missing or different, through a temporary file beside it. Under the lock. Needs shims.sh. 1 with the reason
  local src t="$B/drive_c/ProgramData/revit-macos/dpapi/dpapi.exe" out
  out="$(ensure_shim dpapi 2>&1)" || { tail -1 <<<"$out"; return 1; }
  src="$(shim_dir)/dpapi/dpapi.exe"; [ -f "$src" ] || { echo "no $src"; return 1; }
  cmp -s "$src" "$t" && return 0
  mkdir -p "$(dirname "$t")" && cp "$src" "$t.tmp.$$" && mv -f "$t.tmp.$$" "$t" || { rm -f "$t.tmp.$$"; echo "cannot write $t"; return 1; }
}
pymcp_listener() { # $1 = port: who listens there — ok (one listener on 127.0.0.1, a wineserver of this bottle), none,
  # network (on every address, or another than 127.0.0.1) or foreign (another program)
  local out pids addr p rb
  out="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpn 2>/dev/null)"
  pids="$(sed -n 's/^p//p' <<<"$out" | sort -u)"; [ -n "$pids" ] || { echo none; return 0; }
  addr="$(sed -n 's/^n//p' <<<"$out" | sort -u)"
  [ "$(wc -l <<<"$pids" | tr -d ' ')" = 1 ] && [ "$addr" = "127.0.0.1:$1" ] || {
    grep -qv "^127\.0\.0\.1:" <<<"$addr" && { echo network; return 0; }; echo foreign; return 0; }
  rb="$(cd "$B" 2>/dev/null && pwd -P)"; p="$pids"
  [ "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" = wineserver ] && lsof -p "$p" -Fn 2>/dev/null | grep -qF "n$rb/" \
    && { echo ok; return 0; }
  echo foreign
}
