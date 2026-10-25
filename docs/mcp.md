# Connect an AI assistant to Revit

An AI assistant on your Mac (Claude Code, Claude Desktop, Cursor) can read the model open in Revit and, if you allow
it, change it, through an MCP server. This project starts two of them for you:

| Server | Revit versions | What the assistant can do | What it turns on |
|---|---|---|---|
| [Autodesk Revit MCP Server](#autodesk-revit-mcp-server) | 2027 | Ready-made tools: query the model, read elements, change parameters, move and rotate. No new walls, floors or doors | Autodesk analytics (ADP); a Technical Preview |
| [pyRevit's agent](#pyrevits-agent) | 2023–2027, with the pyRevit that `./revit addins` installs | Runs Python inside Revit: reads the model, builds elements, captures views | Nothing else |

What has been tried on which version is on the [version pages](../versions/).

For both:

- **Your AI assistant sends what it reads from the model to its provider** (Anthropic, OpenAI and so on).
- **Anyone who uses this Mac under your macOS account can connect** to the Revit you have open.
- While an assistant is connected, `./revit addins`, `rebuild` and `remove` refuse to run. Close the assistant first.
- **Stop:** close the assistant, or run `./revit stop 2027` (it quits Revit too).

## Autodesk Revit MCP Server

Autodesk's Revit MCP Server is a Technical Preview from Autodesk, an add-in for Revit 2027.

Before you install it:

- **It turns on Autodesk analytics (ADP) in that bottle.** Autodesk's MCP add-in does not run without it. A plain
  `./revit install` leaves it out; only this add-in installs it.
- Autodesk's preview stops working in May 2028.

### Install

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

### Connect

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

### Read only, or changes too

`./revit mcp 2027` lets the assistant only read: query the model, read elements, open, show and select views and
elements, export views. To let it change the model, add `--write` (`"args": ["mcp", "2027", "--write"]`): it can then
change parameters and move or rotate elements. Ask it to review the changes: Autodesk's review lists the elements its
last change added, modified or deleted.

**Experimental-Tools** is a second installer from the same page (`PublicMcpServerExperimental.exe`) with about 40 tools:
sheets, views, schedules, deleting elements, exports. Autodesk offers it at your own risk. Install it the same way
with `revitmcp-experimental` in place of `revitmcp`. A bottle holds one of the two; to switch, run
`./revit rebuild 2027` and install the other.

### Troubleshoot

- **"The Revit MCP add-in has not opened its connection":** analytics may be off, the add-in may not have loaded, or
  the preview has expired. Run `./revit doctor 2027`; if it finds nothing, install the add-in again (step 3).
- **"Open Revit 2027 with a model first":** start Revit, open a model, then reconnect the assistant.

Autodesk's announcement: [Revit Public MCP Server](https://www.autodesk.com/blogs/aec/2026/06/17/revit-public-mcp-server/).

## pyRevit's agent

pyRevit 7, which `./revit addins` installs for Revit 2023 to 2027, has an agent: the assistant writes Python and pyRevit
runs it inside Revit. It can read anything in the model, build walls, floors and roofs, and take a picture of a view.

Before you turn it on: the scripts run with your rights in the bottle, and the bottle reaches your home folder, so they
can read and write your files too. Connect only assistants you trust.

### Turn it on

1. If pyRevit is not there yet, quit Revit and install it: `./revit addins 2027 --only pyrevit`.
2. In Revit: **pyRevit → Settings → Agent Runtime (MCP)**, tick **Agent Host (Beta)** and choose **Ask for my approval
   in Revit before every change** under Model Changes. Save the settings, then reload pyRevit (**pyRevit → Reload**).

With "Ask for my approval", Revit asks before every change; "Auto" applies changes without asking. The buttons under
"Connect an Agent" in those settings do not work on a Mac: use the command below instead.

`./revit doctor 2027 --all` then lists "pyRevit's agent is on".

### Connect

Open Revit with a model, then give your assistant the full path to `revit` in this project folder:

- **Claude Code:**
  ```bash
  claude mcp add --scope user pyrevit -- /full/path/to/revit-macos/revit mcp 2027 --server pyrevit
  ```
- **Claude Desktop** (not tried yet): in `~/Library/Application Support/Claude/claude_desktop_config.json`, then
  restart Claude:
  ```json
  {"mcpServers": {"pyrevit": {"command": "/full/path/to/revit-macos/revit", "args": ["mcp", "2027", "--server", "pyrevit"]}}}
  ```

What the assistant may change is set in pyRevit's settings, not here: `--write` is for Autodesk's server only.

### Troubleshoot

`./revit mcp` says what is missing before the assistant starts; the assistant shows it as the server's error:

- **"Turn on pyRevit's agent":** follow [Turn it on](#turn-it-on), then reconnect the assistant.
- **"pyRevit's agent is on but not running in this Revit":** pyRevit → Reload, or restart Revit.
- **"pyRevit's agent needs pyRevit 7":** this Revit version gets an older pyRevit here.
- **"Open Revit 2027 with a model first":** start Revit, open a model, then reconnect the assistant.
