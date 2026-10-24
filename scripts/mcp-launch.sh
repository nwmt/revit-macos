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
exec 3>&1 1>&2   # fd 3 = the client's stdout, for the server only
[ $# = 4 ] && [[ "$1" =~ ^[0-9]{4}$ ]] && { [ "$3" = 0 ] || [ "$3" = 1 ]; } && { [ "$4" = autodesk ] || [ "$4" = pyrevit ]; } \
  || { echo "Usage: scripts/mcp-launch.sh <year> <bottle> <0|1> <autodesk|pyrevit>"; exit 2; }
YEAR="$1"; NAME="$2"; WRITE="$3"; SERVER="$4"; B="$(bottle_path "$NAME")"; SFX="$(bottle_sfx "$NAME" "$YEAR")"
TOKEN=""; WPID=""; LF=""; PHASE=starting; SEEN=""
HANDOFF_S="${MCP_HANDOFF_S:-30}"   # how long the launcher may take to confirm (tests shorten it)

checks() { # the bottle, a running Revit, a complete MCP Server install (sets ID, its variant) or pyRevit's agent
  bottle_guard running_ok "$YEAR" "$NAME"
  [ "$SERVER" = autodesk ] || { checks_pyrevit; return; }
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
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_'; }   # $1 = pid: its start time, one word
own_scan() { # OWN = this connection's processes: the background wine and what it started, and every process with the token
  # in its command line (each Windows process under Wine is a Mac process). Every one seen is remembered with its start
  # time (in SEEN): a child whose parent has ended is no longer found from wine, and a reused PID is not ours. Runs in
  # this shell, not in $(…), so SEEN keeps growing
  local p s e found; OWN=""
  found="$({ [ -z "$WPID" ] || { kill -0 "$WPID" 2>/dev/null && echo "$WPID"; descendants "$WPID"; }
    [ -z "$TOKEN" ] || pgrep -f -- "$TOKEN" 2>/dev/null; } | grep -vx -e "$$" -e "${BASHPID:-$$}" | sort -u)"
  for p in $found; do
    s="$(started "$p")"; [ -n "$s" ] || continue
    case " $SEEN " in *" $p:$s "*) ;; *) SEEN="$SEEN $p:$s" ;; esac
  done
  for e in $SEEN; do [ "$(started "${e%%:*}")" != "${e#*:}" ] || OWN="$OWN ${e%%:*}"; done
  OWN="${OWN# }"
}
kill_own_tree() { # TERM, KILL after 3 s, then wait for wine; 1 when something is still there after 10 s
  local p i
  own_scan; [ -z "$OWN" ] || kill -TERM $OWN 2>/dev/null
  for i in $(seq 1 30); do own_scan; [ -n "$OWN" ] || break; sleep 0.1; done
  own_scan; [ -z "$OWN" ] || kill -KILL $OWN 2>/dev/null
  [ -z "$WPID" ] || wait "$WPID" 2>/dev/null
  for i in $(seq 1 100); do own_scan; [ -n "$OWN" ] || return 0; sleep 0.1; done
  return 1
}
finish() { # $1 = exit code: ends this connection's processes; before the handoff the lock (fd 9) stays held until
  # they are gone, so no late mcphost can appear in a bottle that is meanwhile removed
  FCODE="$1"; trap '' INT TERM HUP
  if ! kill_own_tree; then
    own_scan; echo "Processes of this connection did not end: $OWN"
    if [ "$PHASE" = starting ]; then
      trap 'exit "$FCODE"' INT TERM HUP
      while own_scan; [ -n "$OWN" ]; do sleep 1; done
    fi
  fi
  [ -z "$LF" ] || rm -f "$LF"
  exit "$FCODE"
}
on_signal() { finish "$2"; }   # $1 = signal, $2 = exit code

checks
[ -z "${MCP_TEST_HOLD:-}" ] || { touch "$MCP_TEST_HOLD.reached"; while [ -e "$MCP_TEST_HOLD" ]; do sleep 0.1; done; }   # tests
trap 'on_signal INT 130' INT; trap 'on_signal TERM 143' TERM; trap 'on_signal HUP 129' HUP
lock_take --no-trap "./revit mcp $YEAR $NAME"
checks   # again, under the lock: the bottle or Revit may have changed meanwhile
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
