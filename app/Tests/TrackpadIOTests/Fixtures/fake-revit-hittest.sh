#!/bin/bash
# Plays "revit hittest <year> <bottle>" for HittestClientTests. FAKE_HIT_MODE: normal | nohello | slow | wrongseq | long |
# busy (exit 75) | crash (exit 1 after hello). Each start appends a line to $FAKE_HIT_COUNT. A child (sleep) shows that
# the client ends the whole group.
[ "$1" = hittest ] || exit 2
echo start >> "$FAKE_HIT_COUNT"
sleep 61.$$ &
case "${FAKE_HIT_MODE:-normal}" in
  busy) exit 75 ;;
  nohello) cat >/dev/null; exit 0 ;;
esac
echo "hello 1 0 0 3024 1964"
[ "$FAKE_HIT_MODE" = crash ] && exit 1
while read -r seq x y; do
  case "$FAKE_HIT_MODE" in
    slow) sleep 0.3; printf '%s\tAfxFrameOrView140u\t\tA\tFloor Plan: L1\t.\n' "$seq" ;;
    wrongseq) printf '%s\tA\t\t.\n' "$((seq + 1000))" ;;
    long) head -c 5000 /dev/zero | tr '\0' x; echo ;;
    *) printf '%s\tAfxFrameOrView140u\t\tA\tFloor Plan: %s %s\t.\n' "$seq" "$x" "$y" ;;
  esac
done
