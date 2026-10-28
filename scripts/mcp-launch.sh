#!/usr/bin/env bash
# ./revit mcp <year> [bottle] [--write] [--server pyrevit]: connects an AI assistant on this Mac to the Revit running in
# a bottle, through Autodesk's Revit MCP Server (scripts/addins/revitmcp.sh) or pyRevit's agent (pyrevit.exe mcp), and
# our launcher mcphost.exe (tools/shims/mcphost; --plain for pyRevit, which finds Revit without the pipe listing). The MCP
# client starts this command and talks to the server over stdin/stdout, so stdout carries MCP only: everything of this
# script goes to stderr. Exit code: the server's. docs/mcp.md is the how-to.
# The lock is held only while the launcher starts: until mcphost.exe has written its launch confirmation, nothing else
# may delete or change the bottle; afterwards a running mcphost.exe counts as activity for bottle_guard, as Revit does.
# On a signal, the deadline or an error, only this connection's own processes are ended (never wineserver -k: Revit and
# other clients keep running).
# Usage: scripts/mcp-launch.sh <year> <bottle> <0|1: --write> <autodesk|pyrevit>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/addins.sh"; . "$ROOT/scripts/lib/shims.sh"
. "$ROOT/scripts/lib/handoff.sh"
exec 3>&1 1>&2   # fd 3 = the client's stdout, for the server only
[ $# = 4 ] && [[ "$1" =~ ^[0-9]{4}$ ]] && { [ "$3" = 0 ] || [ "$3" = 1 ]; } \
  && { [ "$4" = autodesk ] || [ "$4" = pyrevit ] || [ "$4" = python ]; } \
  || { echo "Usage: scripts/mcp-launch.sh <year> <bottle> <0|1> <autodesk|pyrevit|python>"; exit 2; }
YEAR="$1"; NAME="$2"; WRITE="$3"; SERVER="$4"; B="$(bottle_path "$NAME")"; SFX="$(bottle_sfx "$NAME" "$YEAR")"
TOKEN=""; WPID=""; LF=""; PHASE=starting; SEEN=""
HANDOFF_S="${MCP_HANDOFF_S:-30}"   # how long the launcher may take to confirm (tests shorten it)

checks() { # the bottle, a running Revit, a complete MCP Server install (sets ID, its variant) or pyRevit's agent
  bottle_guard running_ok "$YEAR" "$NAME"
  [ "$SERVER" != python ] || { checks_python; return; }
  [ "$SERVER" = autodesk ] || { checks_pyrevit; return; }
  addin_load revitmcp; addin_available || die "Autodesk's Revit MCP Server is for Revit ${ADDIN_TESTED[*]} only."
  revit_running "$B" "$YEAR" || die "Open Revit $YEAR with a model first."
  ID="$(mcp_installed_variant)"
  [ -n "$ID" ] || die "The Revit MCP Server is not installed in $NAME. Install it: ./revit addins $YEAR$SFX --only revitmcp --accept-eula revitmcp"
  mcp_ready "$ID" || die "The Revit MCP Server in $NAME is not complete ($(mcp_missing "$ID") is missing). Install it again: ./revit addins $YEAR$SFX --only $ID --accept-eula $ID"
}
checks_pyrevit() { # pyRevit's files first (no use opening Revit for a year without it), then the running Revit, then
  # whether its agent runs there
  local m; m="$(pyrevit_mcp_missing "$YEAR")"
  case "$m" in
    not-offered) die "pyRevit is not available for Revit $YEAR here." ;;
    not-installed) die "pyRevit is not installed in $NAME. Install it: ./revit addins $YEAR$SFX --only pyrevit" ;;
    no-agent-runtime) die "pyRevit's agent needs pyRevit 7; Revit $YEAR gets pyRevit $(pyrevit_version_offered "$YEAR") here." ;;
    agent-off) die "Turn on pyRevit's agent: pyRevit → Settings → Agent Runtime → Agent Host, Save, then reload pyRevit." ;;
  esac
  revit_running "$B" "$YEAR" || die "Open Revit $YEAR with a model first."
  [ "$m" != not-registered ] || die "pyRevit's agent is on but not running in this Revit: reload pyRevit or restart Revit."
}

# --server python: the MCP server for Revit (Python) (scripts/addins/python-mcp.sh). Its server runs on the Mac
# (tools/python_mcp_run.py, upstream main.py) and talks to pyRevit Routes on 127.0.0.1:48884; no Wine after the token
PORT="${PYMCP_ROUTES_PORT:-48884}"   # PYMCP_* knobs are for tests only: a real Revit may listen on 48884 there
checks_python() { # the add-in, a running Revit, the extension loaded, Routes of this bottle on 127.0.0.1, the pairing
  local f
  addin_load python-mcp; addin_available || die "MCP server for Revit (Python) is for Revit 2020 here."
  addin_is_installed || die "MCP server for Revit (Python) is not installed in $NAME. Install it: ./revit addins $YEAR$SFX --only python-mcp --accept-eula python-mcp"
  revit_running "$B" "$YEAR" || die "Open Revit $YEAR with a model first."
  f="$B/$PYMCP_LOCAL_REL/startup-error.txt"
  [ ! -f "$f" ] || die "The MCP extension failed to load in Revit: $(head -1 "$f" | tr -d '\r'). Reload pyRevit; if it repeats, run ./revit report $YEAR$SFX."
  case "$(pymcp_listener "$PORT")" in
    none) die "Turn on pyRevit Routes, or reload pyRevit: nothing answers on 127.0.0.1:$PORT." ;;
    network) die "pyRevit Routes listens on the network: run ./revit addins $YEAR$SFX --only python-mcp --accept-eula python-mcp again." ;;
    foreign) die "Port $PORT is taken by another program or another Revit: close it and try again." ;;
  esac
  [ -f "$B/$PYMCP_LOCAL_REL/pairing.dpapi" ] || die "In Revit: MCP → Bridge → Connect, then try again."
}
python_token() { # the pairing token, decrypted once by dpapi.exe in the bottle within PYMCP_DPAPI_S (30) s; on the
  # deadline only that dpapi.exe ends. Stdout: the token (into a variable, never a file)
  local s="${PYMCP_DPAPI_S:-30}" pairing='C:\users\crossover\AppData\Local\RevitMCPPython\pairing.dpapi'
  ( "$CX/bin/wine" --bottle "$NAME" "$PYMCP_DPAPI_WIN" unprotect "$pairing" 2>/dev/null </dev/null 7>&- 8>&- 9>&- &
    wp=$!
    ( sleep "$s"; kill -TERM "$wp" 2>/dev/null; sleep 1; kill -KILL "$wp" 2>/dev/null ) >/dev/null 2>&1 7>&- 8>&- 9>&- &
    kp=$!; wait "$wp"; rc=$?; kill "$kp" 2>/dev/null; exit "$rc" )
}
python_status() { # $1 = token: GET /revit_mcp/status/ within PYMCP_STATUS_S (10) s; the token goes to curl on stdin
  local out rc code body
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$1" \
    | curl -s -m "${PYMCP_STATUS_S:-10}" -K - -w '\n%{http_code}' "http://127.0.0.1:$PORT/revit_mcp/status/" 2>/dev/null)"; rc=$?
  [ $rc != 28 ] || die "Revit does not answer: close any dialog in Revit, or run ./revit stop $YEAR$SFX."
  [ $rc = 0 ] || die "Unexpected answer from Revit (no answer, curl $rc)."
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  case "$code" in
    200) printf '%s' "$body" | /usr/bin/perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) };
           exit(($j && ref $j eq "HASH" && ($j->{status} // "") eq "active") ? 0 : 1)' \
           || die "Unexpected answer from Revit (HTTP 200)." ;;
    401) die "The pairing changed. In Revit: MCP → Bridge → Connect again, then try again." ;;
    503) die "Open a model in Revit $YEAR." ;;
    404) die "The MCP extension is not loaded: reload pyRevit (pyRevit → Reload)." ;;
    *) die "Unexpected answer from Revit (HTTP $code)." ;;
  esac
}
python_launch() { # under the lock, after checks: dpapi.exe, the token, the status, then exec the marked wrapper with
  # the token on a pipe (fd 4) and the lock (fd 9): the wrapper closes fd 9 once it runs, so the bottle is never
  # unguarded between the two
  local why tok rb
  why="$(dpapi_ensure)" || die "Cannot get dpapi.exe: $why"
  tok="$(python_token)" && [[ "$tok" =~ ^[0-9a-f]{64}$ ]] || die "In Revit: MCP → Bridge → Connect again (the pairing could not be read)."
  python_status "$tok"
  [ -z "${PYMCP_EXEC_HOLD:-}" ] || { touch "$PYMCP_EXEC_HOLD.reached"; while [ -e "$PYMCP_EXEC_HOLD" ]; do sleep 0.1; done; }   # tests
  rb="$(cd "$B" && pwd -P)"
  exec "$(pymcp_venv_python)" -I "$ROOT/tools/python_mcp_run.py" revit-macos-python-mcp "$rb" "$(pymcp_dir)/src" \
    --token-fd 4 --lock-fd 9 4< <(printf %s "$tok") >&3 3>&- 7>&- 8>&-
}

checks
[ -z "${MCP_TEST_HOLD:-}" ] || { touch "$MCP_TEST_HOLD.reached"; while [ -e "$MCP_TEST_HOLD" ]; do sleep 0.1; done; }   # tests
trap 'on_signal INT 130' INT; trap 'on_signal TERM 143' TERM; trap 'on_signal HUP 129' HUP
lock_take --no-trap "./revit mcp $YEAR $NAME"
checks   # again, under the lock: the bottle or Revit may have changed meanwhile
[ "$SERVER" != python ] || python_launch
if [ "$SERVER" = pyrevit ]; then why="$(plain_host_ensure)" || die "Cannot get mcphost.exe: $why"; fi

TOKEN="revit-mcp-$(uuidgen | tr 'A-Z' 'a-z')"
if [ "$SERVER" = pyrevit ]; then
  host='C:\ProgramData\revit-macos\mcphost\mcphost.exe'; mode=(--plain)
  server=('C:\users\crossover\AppData\Roaming\pyRevit-Master\bin\pyrevit.exe' mcp "--revit=$YEAR")
else
  case "$ID$WRITE" in
    *0) args=(--tool-permission=StableReadOnly) ;;
    revitmcp1) args=(--tool-permission=Stable --tool-min-permission=StableReadOnly) ;;
    revitmcp-experimental1) args=(--tool-permission=Experimental --tool-min-permission=StableReadOnly) ;;
  esac
  D="C:\\Program Files\\Autodesk\\$(mcp_field "$ID" 2)"
  host="$D\\mcphost.exe"; mode=(); server=("$D\\$MCP_SERVER_EXE" "${args[@]}")
fi
LF="$B/drive_c/users/crossover/AppData/Local/Temp/revit-macos-mcp/launch-$TOKEN"
# the client's stdin explicitly: bash gives a background job /dev/null otherwise. fd 7/8/9 (events, lock) stay here
"$CX/bin/wine" --bottle "$NAME" "$host" --launch "$TOKEN" ${mode[@]+"${mode[@]}"} -- "${server[@]}" \
  <&0 >&3 3>&- 7>&- 8>&- 9>&- &
WPID=$!
i=0
until [ -s "$LF" ] && pgrep -f -- "$TOKEN" >/dev/null 2>&1; do
  if ! kill -0 "$WPID" 2>/dev/null; then   # ended already: the client closed stdin at once, or the launcher failed
    wait "$WPID"; rc=$?; [ $rc = 0 ] || echo "The MCP Server launcher ended (exit $rc)."; finish "$rc"
  fi
  i=$((i + 1)); [ $i -le $((HANDOFF_S * 5)) ] || { echo "The MCP Server launcher did not start within $HANDOFF_S s."; finish 1; }
  sleep 0.2
done
exec 9>&-; PHASE=running   # handed over: a running mcphost.exe now keeps install, rebuild, remove and addins away
rc=0
while :; do wait "$WPID"; rc=$?; kill -0 "$WPID" 2>/dev/null || break; done   # a trap interrupts wait
rm -f "$LF"
exit "$rc"
