# Connect an AI assistant to Revit 2027

Autodesk's Revit MCP Server lets an AI assistant on your Mac (Claude Desktop, Claude Code, Cursor) read the model
open in Revit 2027 and, if you allow it, change it. It is a Technical Preview from Autodesk, an add-in for Revit 2027.

Before you install it:

- **It turns on Autodesk analytics (ADP) in that bottle.** Autodesk's MCP add-in does not run without it. A plain
  `./revit install` leaves it out; only this add-in installs it.
- **Your AI assistant sends what it reads from the model to its provider** (Anthropic, OpenAI and so on).
- **Anyone who uses this Mac under your macOS account can connect** to the Revit you have open.
- Autodesk's preview stops working in May 2028.

## Install

1. Download the installer from your Autodesk Account: **Products and Services → Product Updates → Revit 2027 →
   Revit MCP Server Write-Tools Technical Preview**. The file is `PublicMcpServer.exe`.
2. Put it in its place:
   ```bash
   ./revit addins import revitmcp ~/Downloads/PublicMcpServer.exe
   ```
3. Quit Revit 2027, then install it. `--accept-eula revitmcp` says you accept Autodesk's license and the analytics:
   ```bash
   ./revit addins 2027 --only revitmcp --accept-eula revitmcp
   ```

`./revit doctor 2027` then says whether it is ready.

## Connect

Open Revit 2027 with a model. Your assistant starts `./revit mcp 2027` itself; give it the full path to `revit` in
this project folder (`pwd` in Terminal shows the folder).

- **Claude Code:**
  ```bash
  claude mcp add revit-2027 -- /full/path/to/revit-macos/revit mcp 2027
  ```
- **Claude Desktop:** in `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude:
  ```json
  {"mcpServers": {"revit-2027": {"command": "/full/path/to/revit-macos/revit", "args": ["mcp", "2027"]}}}
  ```

The model's tools appear once the server has found Revit, a few seconds after the start. If your assistant lists only
`get_running_revit_instances`, reconnect it.

## Read only, or changes too

`./revit mcp 2027` lets the assistant only read: query the model, read elements, open, show and select views and
elements, export views. To let it change the model, add `--write` (`"args": ["mcp", "2027", "--write"]`): it can then
change parameters and move or rotate elements. Ask it to review the changes: Autodesk's review lists every element it
changed in this session.

**Experimental-Tools** is a second installer from the same page (`PublicMcpServerExperimental.exe`) with about 40 tools:
sheets, views, schedules, deleting elements, exports. Autodesk offers it at your own risk. Install it the same way
with `revitmcp-experimental` in place of `revitmcp`. A bottle holds one of the two; to switch, run
`./revit rebuild 2027` and install the other.

## Stop and troubleshoot

- **Stop:** close the assistant, or run `./revit stop 2027` (it quits Revit too).
- While an assistant is connected, `./revit addins`, `rebuild` and `remove` refuse to run. Close the assistant first.
- **"The Revit MCP add-in has not opened its connection":** analytics may be off, the add-in may not have loaded, or
  the preview has expired. Run `./revit doctor 2027`; if it finds nothing, install the add-in again (step 3).
- **"Open Revit 2027 with a model first":** start Revit, open a model, then reconnect the assistant.

Autodesk's announcement: [Revit Public MCP Server](https://www.autodesk.com/blogs/aec/2026/06/17/revit-public-mcp-server/).
