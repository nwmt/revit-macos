# Connect an AI assistant to Revit

An AI assistant on your Mac (Claude Code, Claude Desktop, Cursor) can read the model open in Revit and, if you allow
it, change it, through an MCP server. This project starts four of them for you:

| Server | Revit versions | What the assistant can do | What it turns on |
|---|---|---|---|
| [Autodesk Revit MCP Server](#autodesk-revit-mcp-server) | 2027 | Ready-made tools: query the model, read elements, change parameters, move and rotate. No new walls, floors or doors | Autodesk analytics (ADP); a Technical Preview |
| [pyRevit's agent](#pyrevits-agent) | 2023–2027, with the pyRevit that `./revit addins` installs | Runs Python inside Revit: reads the model, builds elements, captures views | Nothing else |
| [MCP server for Revit (Python)](#mcp-server-for-revit-python) | 2020 | Ready-made tools (model, levels, views as pictures, families, colors, save) and Python inside Revit; you approve each change in Revit | pyRevit Routes, on this Mac only |
| [Revit's windows](#revits-windows) | 2027 | Works Revit's interface, not the model: sees windows and dialogs, runs any command by name, answers dialogs, clicks. For what the API does not reach | Nothing in the model. Needs pyRevit once, for the command table |

What has been tried on which version is on the [version pages](../versions/).

For all of them:

- **Your AI assistant sends what it reads from the model to its provider** (Anthropic, OpenAI and so on).
- A connection needs a token, and the token sets what it may do: see [Tokens and tiers](#tokens-and-tiers).
- While an assistant is connected, `./revit addins`, `rebuild` and `remove` refuse to run. Close the assistant first.
- **Stop:** close the assistant, or run `./revit stop <year>` (it quits Revit too).

## Tokens and tiers

`./revit mcp` starts only with a token. In the app, open a Revit's **AI Assistant** tab and choose **New connection**:
your Mac asks for Touch ID or its password, then the token is shown once. Without the app, make one in Terminal, once for
each assistant:

```bash
./revit mcp token 2027 --server pyrevit --tier code --name my-assistant
```

It is shown once, with the command that connects Claude Code. For Claude Desktop, see
[Claude Desktop](#claude-desktop). The assistant passes it in the environment variable `REVIT_MCP_TOKEN`; Revit-side
add-ins never see it. A token is for one bottle and one server. `./revit mcp tokens` lists them;
`./revit mcp revoke <name>` ends that assistant's connection within two seconds. What Revit is already doing goes on.

| Tier | What the assistant may do |
|---|---|
| `read` (the default) | Read the model, show and select elements, take pictures of views |
| `write` | Also change the model with the server's ready-made tools. pyRevit has no such tier: it changes the model by running code |
| `code` | Everything the server offers, running code included. Python runs with your rights and can reach your files. Autodesk's server has this tier only with Experimental-Tools |

Below `code`, a tool this project has not sorted into a tier stays hidden, so a new tool of a new server version needs
an update here first.

Every connection is logged in `mcp/audit/<bottle>.jsonl`, under the project folder (under
`~/Library/Application Support/` for the app): when, which token, which tool, allowed or refused, and how it went.
It keeps the first 4 KB of what the assistant sent, so it may hold anything the assistant put in a script. It keeps no
answers, and `./revit report` leaves it out. If the log cannot be written, the call is not made.

The tab also lists connections, revokes them and shows the calls. Its log says whether a call was refused or answered,
not what Revit did with it. **Show Revit to computer use** does what `./revit agent-view` does, after the same question.
Revoke does not end that: it ends when Revit quits.

**What a token does not do.** It says what a connection may do; it is not a lock. A program that runs under your macOS
account and sets out to get around it can: it can start Wine itself, edit the token file or read your models from disk.
Connect only assistants you trust, and let only those run commands on your Mac.

## Claude Desktop

Make a bundle for the server you want:

```bash
./revit mcp bundle 2027 --server pyrevit --tier code
```

It puts `revit-<bottle>-<server>.mcpb` in `~/Downloads` and shows a token. In Claude Desktop, open **Settings →
Extensions → Advanced settings → Install Extension**, choose the file and paste the token: Claude Desktop keeps it in
your Keychain. The file holds no token, and it points at this folder, so make it again if you move the project.

## When it refuses

- **"This connection needs a token":** make one, as above, then reconnect the assistant. Connections made before tokens
  existed need this once.
- **"This token is not valid for…":** the token is for another bottle or server, or it was revoked or replaced.
- **"What a connection may do now comes with its token":** remove `--write` and make a token with `--tier write`.
- **The assistant says it may not use a tool:** its token's tier does not cover it.
- **"Cannot write the log of MCP calls":** free disk space, or check `mcp/audit`.

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

Open Revit 2027 with a model and make a token: `./revit mcp token 2027` for reading, `--tier write` to allow changes.

- **Claude Code:** run the `claude mcp add` command it prints. The token then sits in plain text in `~/.claude.json`,
  and in your shell history.
- **Claude Desktop:** [make a bundle](#claude-desktop).

The model's tools appear once the server has found Revit, a few seconds after the start. If your assistant lists only
`get_running_revit_instances`, reconnect it.

### Read only, or changes too

A `read` token lets the assistant query the model, read elements, open, show and select views and elements, and export
views. A `write` token also lets it change parameters and move or rotate elements. Ask it to review the changes: Autodesk's review lists the elements its
last change added, modified or deleted.

**Experimental-Tools** is a second installer from the same page (`PublicMcpServerExperimental.exe`) with about 40 tools:
sheets, views, schedules, deleting elements, exports. Autodesk offers it at your own risk. Install it the same way
with `revitmcp-experimental` in place of `revitmcp`; its extra tools need a `code` token. A bottle holds one of the two; to switch, run
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
can read and write your files too. pyRevit's `readonly` policy stops changes to the model, not this. Connect only
assistants you trust.

### Turn it on

1. If pyRevit is not there yet, quit Revit and install it: `./revit addins 2027 --only pyrevit`.
2. In Revit: **pyRevit → Settings → Agent Runtime (MCP)**, tick **Agent Host (Beta)** and choose **Ask for my approval
   in Revit before every change** under Model Changes. Save the settings, then reload pyRevit (**pyRevit → Reload**).

With "Ask for my approval", Revit asks before every change; "Auto" applies changes without asking. The buttons under
"Connect an Agent" in those settings do not work on a Mac: use the command below instead.

`./revit doctor 2027 --all` then lists "pyRevit's agent is on".

### Connect

Open Revit with a model and make a token. Reading a model needs Python, so most of this server needs `--tier code`:

```bash
./revit mcp token 2027 --server pyrevit --tier code
```

Then run the `claude mcp add` command it prints, or [make a bundle](#claude-desktop) for Claude Desktop.
A `read` token gives the tools that run no code: context, element details, pictures of views.

pyRevit's own setting still applies on top: with **Ask**, Revit asks before every change. With **Auto**, `./revit mcp`
warns you when it starts.

### Troubleshoot

`./revit mcp` says what is missing before the assistant starts; the assistant shows it as the server's error:

- **"Turn on pyRevit's agent":** follow [Turn it on](#turn-it-on), then reconnect the assistant.
- **"pyRevit's agent is on but not running in this Revit":** pyRevit → Reload, or restart Revit.
- **"pyRevit's agent needs pyRevit 7":** this Revit version gets an older pyRevit here.
- **"Open Revit 2027 with a model first":** start Revit, open a model, then reconnect the assistant.

## MCP server for Revit (Python)

[MCP server for Revit (Python)](https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python) is an open
source pyRevit extension. Here it is for Revit 2020, whose pyRevit has no agent of its own.

Before you install it:

- **It turns on pyRevit Routes**, a small web server inside Revit, reachable from this Mac only.
- **It changes one file of pyRevit 4.8** so that Routes passes on the pairing and serves one request at a time.
- **With a `code` token, the assistant can run Python inside Revit without a sandbox.** Revit shows every change and
  every script before it runs, and runs it only if you click **Yes**.

### Install

1. Quit Revit. Install pyRevit if it is not there yet: `./revit addins 2020 --only pyrevit`.
2. Install the server and accept its license:
   ```bash
   ./revit addins 2020 --only python-mcp --accept-eula python-mcp
   ```
   It downloads the extension and the Python packages it needs on the Mac (internet needed once).
3. Start Revit and open a model. In Revit: **MCP → Bridge → Connect**, read the notice and click **Yes**. This pairs
   Revit with the assistants on this Mac; **Disconnect** undoes it.

`./revit doctor 2020 --all` then lists "the MCP server for Revit (Python) is ready".

### Connect

Open Revit with a model and make a token: `./revit mcp token 2020 --server python`, with `--tier write` for changes or
`--tier code` for Python. Then run the `claude mcp add` command it prints, or [make a bundle](#claude-desktop) for Claude
Desktop (not tried yet).

When the assistant asks to change the model or run Python, Revit shows **Revit MCP request review**. Answer within 30
seconds (60 for Python and pictures of views): after that the assistant stops waiting, though Revit still does what you
allowed.

Two of its tools do nothing on a Mac: `launch_revit` and `list_revit_installations` look for Revit in Windows, outside
the bottle. Start Revit from `~/Applications` instead. Close documents in Revit yourself:
[`close_document` hangs Revit 2020](../versions/2020.md#known-issues).

### Troubleshoot

- **"Turn on pyRevit Routes, or reload pyRevit":** pyRevit → Reload, or restart Revit.
- **"In Revit: MCP → Bridge → Connect":** pair once, as in [Install](#install-1).
- **"The pairing changed" or "Connect again":** you clicked Connect again, so the assistant's copy is old: restart the
  server in the assistant (in Claude Code, `/mcp`, then reconnect `revit-python`).
- **"Revit refused the pairing it has just given":** pyRevit was installed again and undid this add-in's change to it.
  Run `./revit addins 2020 --only python-mcp --accept-eula python-mcp` again, then restart Revit.
- **"Open a model in Revit 2020":** open a model, then reconnect the assistant.
- **"The MCP extension failed to load in Revit":** pyRevit → Reload. If it says so again, run `./revit report 2020`
  and attach the report to an issue.
- **"Revit does not answer":** a dialog in Revit is waiting for you. Close it, or run `./revit stop 2020`.
- **"pyRevit Routes listens on the network":** run the install command again; it puts Routes back on this Mac only.

## Revit's windows

The other servers work with the model. This one works with Revit's interface, the way a person does: it reads what is
on screen, runs commands, answers dialogs and clicks. Use it next to one of them, for what the API does not reach.

Before you connect it:

- **`write` means the whole interface.** An assistant can press any button of any dialog, so it can confirm what you
  would confirm. Exit, save, close and synchronize as commands need a `code` token, but a dialog that offers them
  does not ask for one. A token is a grant, not a wall: a program under your account can start the same helper.
- **It sends pictures of Revit's windows and the text of its dialogs** to your AI assistant's provider.
- **Your mouse pointer jumps for a moment on each click.** A click waits until nobody has used the mouse or keyboard for 3
  seconds, but you can still grab the mouse in the 0.3 seconds it takes. Other actions do not touch the mouse.

### Install

1. If pyRevit is not there yet, quit Revit and install it: `./revit addins 2027 --only pyrevit`.
2. Add the command table: `./revit mcp commands 2027`. The next time Revit starts, it writes the list of its commands
   into the bottle, once for each Revit build. After a Revit update it does so again by itself. Nothing is sent anywhere.

`./revit agent-view 2027` is separate and needs none of this: it makes the running Revit visible to computer use tools
until Revit quits. They can then see it and click dialogs and the Project Browser, but clicks on the ribbon and in the
drawing area do not arrive; use this server for those.

### Connect

Open Revit and make a token: `read` looks, `write` also acts, `code` adds exit, save, close and synchronize.

```bash
./revit mcp token 2027 --server ui --tier write
```

Then run the `claude mcp add` command it prints. For a picture of a window, the app that runs the assistant needs
Screen Recording: System Settings, Privacy & Security, Screen Recording.

### What the assistant sees

`ui_state` lists the windows, `ui_dialog` reads a dialog, `ui_screenshot` takes a picture of a window. `ui_tree` shows what
Windows accessibility offers: ribbon tabs, Quick Access, palettes and WPF dialogs. It does not show the buttons inside
ribbon panels, the Properties grid, the Project Browser or the drawing area: those need a picture, or the other servers.
It reads about 7 elements a second. The main window needs a model open and no dialog over it: on the Home screen or under a
dialog `ui_tree` refuses and says so. If a walk stalls it answers `busy`, and `retry_after` says how many seconds to wait:
2 minutes at first, doubling up to 8 for each walk that stalls.

`ui_commands` finds a command by words in its name, such as `purge unused`. `run_command` runs it and answers:

| Status | Meaning |
|---|---|
| `ran` | Revit's journal shows the command |
| `not_run` | Revit did not run it: it is not available here. This takes about 12 seconds. To prove it, Select Pinned Elements is flipped, and flipped back before the next command or when the connection ends |
| `blocked` | A dialog is open or Revit does not answer. Nothing was sent |
| `unconfirmed`, `pending` | Not known yet: the command may be in Revit's queue. Do not repeat it. No other command goes out until it is settled or Revit quits |

If a dialog opens in the instant between the check and the command, the command still goes through and both dialogs
stay open; the answer says `overlapped`. `set_text` works in Win32 dialogs only, and a file dialog may keep its own name:
check the file afterwards. Password fields are never read or set. The first click on a palette such as the Project Browser only activates it: click once, then double-click to open a view.
A click right after a model opens may be lost too. `press_button` tells whether the dialog is still open:
a button may do nothing, and the Cancel of Keyboard Shortcuts does not react to a click. `close_dialog` closes a dialog as
its X does.

### Troubleshoot

- **`There is no command table`:** run `./revit mcp commands 2027`, then restart Revit.
- **The table has an error:** Revit reads the list of commands from an internal class that a new version may not have.
  `run_command` shows the reason; everything else still works. Report it with `./revit report 2027`.
- **`user_active`:** somebody is using the mouse or keyboard. Wait, or let go of the mouse.
- **`pending` that never ends:** Revit hangs. Quit it with `./revit stop 2027`.
- **No picture of the window:** see Screen Recording above. With the display asleep there are no pictures either.
- **`More than one Revit`:** the server works with one Revit in a bottle.
