#!/usr/bin/env bash
# Checks the app's own tools and shims: each is the one inside the app (not one on the user's PATH) and it runs.
# One line per check, "ok" or "FAIL"; exit 0 only when all pass. Takes no lock and writes nothing.
# Usage (inside the app): <App>.app/Contents/Resources/engine/scripts/check-bundle.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; . "$ROOT/scripts/lib/common.sh"; . "$ROOT/scripts/lib/shims.sh"
app_path >/dev/null || { echo "not inside the app: $(tilde "$ROOT") has no .app-bundle" >&2; exit 1; }
bad=0
version_of() { grep -m1 -oE '[0-9]+\.[0-9]+(\.[0-9]+)?|[0-9]{8}' <<<"$1" | head -1; }
tool() { # $1 = name, rest = how to run it: found in the app and exits 0
  local name="$1" p out; shift
  p="$(command -v "$name")"
  case "$p" in
    "$APP_RES"/*) ;;
    *) echo "FAIL $name: ${p:-not found} is not the app's"; bad=1; return ;;
  esac
  # the version from the first line that is not winetricks' "Executing cd <folder>" (a folder may hold digits)
  if out="$("$@" 2>&1)"; then echo "ok   $name $(version_of "$(grep -v '^Executing ' <<<"$out" | grep -m1 .)") ($p)"
  else echo "FAIL $name: $(tail -1 <<<"$out")"; bad=1; fi
}
tool 7zz 7zz i
tool cabextract cabextract --version
tool winetricks winetricks --version
# _lzma and _hashlib by name: hashlib alone falls back to built-in code when _hashlib cannot load. Then every module
# that tools/*.py import, so a new import is checked too; a tool that imports another tool is checked through that
# tool's own imports (importing it here would write its bytecode into the bundle)
tool python3 python3 -I -c '
import ast, glob, importlib, os, platform, sys
import _hashlib, _lzma, lzma
assert lzma.decompress(lzma.compress(b"x")) == b"x"
_hashlib.new("sha256", b"x").hexdigest()
mods = set()
for f in glob.glob(os.path.join(sys.argv[1], "*.py")):
    with open(f, encoding="utf-8") as h:
        for n in ast.walk(ast.parse(h.read())):
            if isinstance(n, ast.Import):
                mods.update(a.name.split(".")[0] for a in n.names)
            elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                mods.add(n.module.split(".")[0])
mods -= {os.path.basename(f)[:-3] for f in glob.glob(os.path.join(sys.argv[1], "*.py"))}
for m in sorted(mods):
    importlib.import_module(m)
print(platform.python_version())' "$ROOT/tools"
if [ "$(cat "$(shim_dir)/.prebuilt" 2>/dev/null)" = "$SHIMS_VERSION" ] && release_complete "$(shim_dir)"; then
  echo "ok   shims v$SHIMS_VERSION ($(shim_dir))"
else echo "FAIL shims: $(shim_dir) does not hold release v$SHIMS_VERSION"; bad=1; fi
exit $bad
