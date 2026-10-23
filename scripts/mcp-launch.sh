#!/usr/bin/env bash
# ./revit mcp <year> [bottle] [--write]: connects an AI assistant on this Mac to the Revit running in a bottle, through
# Autodesk's Revit MCP Server (scripts/addins/revitmcp.sh) and our launcher mcphost.exe (tools/shims/mcphost). The MCP
# client starts this command and talks to the server over stdin/stdout, so stdout carries MCP only: everything of this
# script goes to stderr. Exit code: the server's. docs/mcp.md is the how-to.
# The lock is held only while the launcher starts: until mcphost.exe has written its launch confirmation, nothing else
# may delete or change the bottle; afterwards a running mcphost.exe counts as activity for bottle_guard, as Revit does.
# On a signal, the deadline or an error, only this connection's own processes are ended (never wineserver -k: Revit and
# other clients keep running).
# Usage: scripts/mcp-launch.sh <year> <bottle> <0|1: --write>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/addins.sh"
exec 3>&1 1>&2   # fd 3 = the client's stdout, for the server only
[ $# = 3 ] && [[ "$1" =~ ^[0-9]{4}$ ]] && { [ "$3" = 0 ] || [ "$3" = 1 ]; } \
  || { echo "Usage: scripts/mcp-launch.sh <year> <bottle> <0|1>"; exit 2; }
YEAR="$1"; NAME="$2"; WRITE="$3"; B="$(bottle_path "$NAME")"; SFX="$(bottle_sfx "$NAME" "$YEAR")"
TOKEN=""; WPID=""; LF=""; PHASE=starting
HANDOFF_S="${MCP_HANDOFF_S:-30}"   # how long the launcher may take to confirm (tests shorten it)

checks() { # the bottle, a running Revit, a complete MCP Server install; sets ID (its variant)
  bottle_guard running_ok "$YEAR" "$NAME"
  revit_running "$B" "$YEAR" || die "Open Revit $YEAR with a model first."
  ID="$(mcp_installed_variant)"
  [ -n "$ID" ] || die "The Revit MCP Server is not installed in $NAME. Install it: ./revit addins $YEAR$SFX --only revitmcp --accept-eula revitmcp"
  mcp_ready "$ID" || die "The Revit MCP Server in $NAME is not complete ($(mcp_missing "$ID") is missing). Install it again: ./revit addins $YEAR$SFX --only $ID --accept-eula $ID"
}
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
own_pids() { # this connection's processes: the background wine and what it started, and every process with the token
  # in its command line (each Windows process under Wine is a Mac process)
  { [ -z "$WPID" ] || { kill -0 "$WPID" 2>/dev/null && echo "$WPID"; descendants "$WPID"; }
    [ -z "$TOKEN" ] || pgrep -f -- "$TOKEN" 2>/dev/null; } | grep -vx -e "$$" -e "${BASHPID:-$$}" | sort -u
}
kill_own_tree() { # TERM, KILL after 3 s, then wait for wine; 1 when something is still there after 10 s
  local p i
  p="$(own_pids)"; [ -z "$p" ] || kill -TERM $p 2>/dev/null
  for i in $(seq 1 30); do [ -n "$(own_pids)" ] || break; sleep 0.1; done
  p="$(own_pids)"; [ -z "$p" ] || kill -KILL $p 2>/dev/null
  [ -z "$WPID" ] || wait "$WPID" 2>/dev/null
  for i in $(seq 1 100); do [ -n "$(own_pids)" ] || return 0; sleep 0.1; done
  return 1
}
finish() { # $1 = exit code: ends this connection's processes; before the handoff the lock (fd 9) stays held until
  # they are gone, so no late mcphost can appear in a bottle that is meanwhile removed
  FCODE="$1"; trap '' INT TERM HUP
  if ! kill_own_tree; then
    echo "Processes of this connection did not end: $(own_pids | tr '\n' ' ')"
    if [ "$PHASE" = starting ]; then
      trap 'exit "$FCODE"' INT TERM HUP
      while [ -n "$(own_pids)" ]; do sleep 1; done
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

case "$ID$WRITE" in
  *0) args=(--tool-permission=StableReadOnly) ;;
  revitmcp1) args=(--tool-permission=Stable --tool-min-permission=StableReadOnly) ;;
  revitmcp-experimental1) args=(--tool-permission=Experimental --tool-min-permission=StableReadOnly) ;;
esac
TOKEN="revit-mcp-$(uuidgen | tr 'A-Z' 'a-z')"
D="C:\\Program Files\\Autodesk\\$(mcp_field "$ID" 2)"
LF="$B/drive_c/users/crossover/AppData/Local/Temp/revit-macos-mcp/launch-$TOKEN"
# the client's stdin explicitly: bash gives a background job /dev/null otherwise. fd 7/8/9 (events, lock) stay here
"$CX/bin/wine" --bottle "$NAME" "$D\\mcphost.exe" --launch "$TOKEN" -- "$D\\$MCP_SERVER_EXE" "${args[@]}" \
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
