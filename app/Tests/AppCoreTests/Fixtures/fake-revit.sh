#!/bin/bash
# A fake engine for the app's tests and the demo, run as /bin/bash fake-revit.sh <args…> like the real revit.
# Without --events (a query): fail → "boom" on stderr, exit 3; $FAKE_DIR/<first argument>.json → printed, exit 0;
#   $FAKE_DIR/<first argument>.err → printed on stderr, exit 1; else "fake: <args>", exit 0.
# With --events <dir> (a long command): records what it got (args.txt, pgid.txt, stdin.txt, env.txt, fds.txt), prints
#   "hello out" and "hello err", waits FAKE_EVENTS_DELAY s, writes start, then by FAKE_SCENARIO: ok, slow (busy in
#   $FAKE_DIR/status.json until INT/TERM ends it as stopped), late (end after 2 s), split (a step line in two writes),
#   noend (killed: no end).
set -u
ctx=""; prev=""
for a in "$@"; do [ "$prev" = --events ] && ctx="$a"; prev="$a"; done
if [ -z "$ctx" ]; then
  [ "${1:-}" = fail ] && { echo boom >&2; exit 3; }
  if [ -n "${FAKE_DIR:-}" ] && [ -f "$FAKE_DIR/${1:-}.json" ]; then cat "$FAKE_DIR/$1.json"; exit 0; fi
  if [ -n "${FAKE_DIR:-}" ] && [ -f "$FAKE_DIR/${1:-}.err" ]; then cat "$FAKE_DIR/$1.err" >&2; exit 1; fi
  echo "fake: $*"; exit 0
fi
mkdir -p "$ctx"
: > "$ctx/args.txt"; for a in "$@"; do printf '%s\n' "$a" >> "$ctx/args.txt"; done
ps -o pgid= -p $$ | tr -d ' ' > "$ctx/pgid.txt"
if read -r -t 1 _line; then echo "data" > "$ctx/stdin.txt"; else echo eof > "$ctx/stdin.txt"; fi
env > "$ctx/env.txt"
: > "$ctx/fds.txt"; for i in $(seq 0 63); do [ -e /dev/fd/$i ] && echo $i >> "$ctx/fds.txt"; done   # this shell's own descriptors
echo "hello out"; echo "hello err" >&2
sleep "${FAKE_EVENTS_DELAY:-0}"
ev="$ctx/events.ndjson"; id="$(basename "$ctx")"
emit() { printf '%s\n' "$1" >> "$ev"; }
end() { emit "{\"event\":\"end\",\"exit_code\":$1,\"result\":\"$2\",\"failed_action\":\"\",\"failed_steps\":[],\"log_dir\":\"\"}"; }
emit "{\"event\":\"start\",\"run_id\":\"$id\",\"command\":\"${1:-}\",\"year\":2025,\"bottle\":\"rvt2025-a\",\"pid\":$$}"
case "${FAKE_SCENARIO:-ok}" in
  ok)
    emit '{"event":"action","id":"shims","state":"running"}'; emit '{"event":"action","id":"shims","state":"done","exit":0}'
    end 0 ok ;;
  slow)
    busy() { # $1 = true | false: what revit status --json says while this run holds the lock
      printf '{"crossover":{"found":true,"path":"/x","version":"26.3.0","supported":true},"rosetta":true,"msls31":true,"busy":{"busy":%s,"command":"install.sh 2025 rvt2025-a","run_id":"%s","pid":"%s","pid_start":"%s","pgid":"%s","ctx":"%s"},"bottles":[]}\n' \
        "$1" "$id" "$$" "$(ps -o lstart= -p $$ | sed 's/^ *//; s/ *$//')" "$$" "$ctx" > "${FAKE_DIR:-$ctx}/status.json"
    }
    busy true
    trap 'end 130 stopped; busy false; exit 130' INT TERM
    emit '{"event":"action","id":"unpack","state":"running"}'
    sleep 30   # in the foreground: a group INT ends it, then the trap runs
    end 0 ok; busy false ;;
  late) sleep 2; end 0 ok ;;
  split)
    printf '%s' '{"event":"step","id":"rvt",' >> "$ev"; sleep 1; printf '%s\n' '"state":"running"}' >> "$ev"; end 0 ok ;;
  noend) kill -9 $$ ;;
esac
exit 0
