# The MCP server for Revit (Python) (github.com/mcp-servers-for-revit/mcp-server-for-revit-python, MIT): a pyRevit
# extension that answers over pyRevit Routes inside Revit, and a Python MCP server on the Mac that an AI assistant
# starts with ./revit mcp 2020 --server python. Revit 2020 only here: its pyRevit 4.8 needs our Routes patch.
# Step pythonmcp (scripts/steps/addins.sh); the Mac side: scripts/lib/pymcp.sh.
ADDIN_NAME="MCP server for Revit (Python)"
ADDIN_ABOUT="AI assistant connection for Revit 2020 (open source)"
ADDIN_NOTICE="It turns on pyRevit Routes on this Mac only and changes one file of pyRevit 4.8; an AI assistant can then read the open model and, after you approve each request in Revit, change it and run Python there without a sandbox."
ADDIN_TESTED=(2020)
ADDIN_EULA="https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python/blob/$PYMCP_COMMIT/LICENSE"
ADDIN_AFTER=()
ADDIN_TOOL=""
ADDIN_STEP=pythonmcp
addin_files() {
  [ "$1" = 2020 ] && printf 'auto\tpython-mcp/%s.tar.gz\t%s\t%s\n' "$PYMCP_COMMIT" \
    "https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python/archive/$PYMCP_COMMIT.tar.gz" \
    6406be6574efe9519b34110ccf04d1499bb47f0e3fc36ba902a30b9575e1f0f6
  return 0
}
addin_is_installed() {
  # pyRevit installed again puts back its own server.py: then this add-in is not installed any more
  [ -f "$B/$PYMCP_EXT_REL/startup.py" ] && pymcp_venv_works \
    && cmp -s "$ROOT/tools/pyrevit48/revitmacos_serial.py" "$(dirname "$(pymcp_server_py)")/revitmacos_serial.py" \
    && [ "$(pymcp_server_state "$(pymcp_server_py)")" = patched ]
}
