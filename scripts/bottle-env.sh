#!/usr/bin/env bash
# Environment variables for ALL processes in the bottle ([EnvironmentVariables] section of cxbottle.conf).
# Needed for processes not started by our command (AdSSO starts the licensing agent).
# Usage:
#   ./scripts/bottle-env.sh <bottle> KEY=VALUE ...   — set
#   ./scripts/bottle-env.sh <bottle> -KEY ...        — remove
#   ./scripts/bottle-env.sh <bottle>                 — show
set -euo pipefail
NAME="${1:?specify a bottle}"; shift
CONF="$HOME/Library/Application Support/CrossOver/Bottles/$NAME/cxbottle.conf"
[ -f "$CONF" ] || { echo "no $CONF" >&2; exit 1; }
python3 - "$CONF" "$@" <<'PY'
import sys, re
conf, args = sys.argv[1], sys.argv[2:]
lines = open(conf, encoding='utf-8').read().split('\n')
start = next(i for i, l in enumerate(lines) if l.strip() == '[EnvironmentVariables]')
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('[')), len(lines))
key_re = re.compile(r'^"([^"]+)"\s*=')
for a in args:
    if a.startswith('-'):
        k = a[1:]; v = None
    else:
        k, v = a.split('=', 1)
    idx = next((i for i in range(start + 1, end) if (m := key_re.match(lines[i])) and m.group(1) == k), None)
    if idx is not None:
        if v is None: del lines[idx]; end -= 1
        else: lines[idx] = f'"{k}" = "{v}"'
    elif v is not None:
        lines.insert(start + 1, f'"{k}" = "{v}"'); end += 1
open(conf, 'w', encoding='utf-8').write('\n'.join(lines))
for i in range(start, end):
    if key_re.match(lines[i]) or lines[i].startswith('['): print(lines[i])
PY
