# SPDX-License-Identifier: MIT
"""Runs the MCP server for Revit (Python)'s main.py on the Mac, for ./revit mcp <year> --server python.

  python_mcp_run.py revit-macos-python-mcp <bottle real path> <src> --token-fd N --lock-fd M

The first two arguments only mark the process (scripts/lib/common.sh pymcp_wrappers finds it by them: ./revit stop
and the bottle guard). <src> is the patched upstream folder (scripts/lib/pymcp.sh). Before anything of upstream is
imported, REVIT_HOST and REVIT_PORT are fixed to 127.0.0.1 and 48884: upstream reads them from the environment, and
the launcher checked that address only. The pairing token comes from fd N (a pipe from the launcher, which decrypted
it with dpapi.exe): never from arguments, the environment or a file; it replaces upstream's get_token, which needs
Windows DPAPI. Fd M is the project lock the launcher held: closed here, once this process is visible by its marker.
Then main.py runs in stdio mode; stdout is the MCP client's. Exit 2: bad arguments or token (one line on stderr).
"""
import os
import re
import runpy
import sys


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def main(argv):
    if len(argv) != 8 or argv[1] != "revit-macos-python-mcp" or argv[4] != "--token-fd" or argv[6] != "--lock-fd":
        die("usage: python_mcp_run.py revit-macos-python-mcp <bottle> <src> --token-fd N --lock-fd M")
    src, token_fd, lock_fd = argv[3], int(argv[5]), int(argv[7])
    os.environ.pop("REVIT_HOST", None)
    os.environ.pop("REVIT_PORT", None)
    os.environ["REVIT_HOST"], os.environ["REVIT_PORT"] = "127.0.0.1", "48884"
    with os.fdopen(token_fd, "r") as f:
        token = f.read(200).strip()
    if not re.fullmatch(r"[0-9a-f]{64}", token):
        die("The pairing token from Revit is not valid. In Revit: MCP > Bridge > Connect again.")
    try:
        os.close(lock_fd)
    except OSError:
        pass
    sys.path.insert(0, src)
    import revit_mcp.pairing as pairing
    pairing.get_token = lambda: token
    sys.argv = [os.path.join(src, "main.py")]
    runpy.run_path(sys.argv[0], run_name="__main__")


if __name__ == "__main__":
    main(sys.argv)
