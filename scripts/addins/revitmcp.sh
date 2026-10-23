# Autodesk's Revit MCP Server, Write-Tools (Technical Preview): lets an AI assistant on the Mac (Claude, Cursor) read
# and, with ./revit mcp --write, change the open model. The installer comes from your Autodesk account
# (./revit addins import revitmcp <file>); its variants and readiness: scripts/lib/mcp.sh. ADDIN_NOTICE (optional) is
# shown before consent, next to the license.
ADDIN_NAME="Revit MCP Server (Write-Tools)"
ADDIN_ABOUT="Autodesk's AI connection for Revit 2027 (Technical Preview)"
ADDIN_NOTICE="$MCP_NOTICE"
ADDIN_TESTED=(2027)
ADDIN_EULA="https://www.autodesk.com/company/terms-of-use/en/general-terms"
ADDIN_AFTER=()
ADDIN_TOOL=""
ADDIN_STEP=revitmcp
addin_files() { [ "$1" = 2027 ] && printf 'own\t%s\t-\t-\n' "$(mcp_field revitmcp 4)"; return 0; }
addin_is_installed() { mcp_ready revitmcp; }
