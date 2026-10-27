# A launcher's own processes (scripts/mcp-launch.sh, scripts/hittest-launch.sh): it starts one wine in the background
# and must end exactly what that started, never wineserver or another client. Source with
# . "$ROOT/scripts/lib/handoff.sh". The launcher sets WPID (the background wine), TOKEN (a word in the command line of
# every process it starts; "" when none), LF (a file to delete at the end; "" when none), PHASE (starting until the
# handoff, then running) and SEEN=""; OWN and FCODE are this file's.
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_'; }   # $1 = pid: its start time, one word
own_scan() { # OWN = the launcher's processes: the background wine and what it started, and every process with the token
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
finish() { # $1 = exit code: ends the launcher's processes; before the handoff the lock (fd 9) stays held until they
  # are gone, so no late Windows program of ours can appear in a bottle that is meanwhile removed
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
