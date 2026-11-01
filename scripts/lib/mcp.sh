# Autodesk's Revit MCP Server (Technical Preview): its two variants, where they install, and when a bottle is ready
# for ./revit mcp. Files only: no Wine, no registry, no installer needed. Source after common.sh; uses $B, $YEAR and
# $DATA. scripts/lib/addins.sh sources it (the catalog's revitmcp entries), and so does scripts/mcp-launch.sh
# Per variant: id | folder under Program Files\Autodesk | MSI inside the ODIS exe | the ODIS exe (installers/addins/) |
# the MSI's ProductCode (the install step asks Wine's live registry with it; pkg.<name>.xml, AdditionalPackageInfo)
MCP_VARIANTS=(
  "revitmcp|Revit 2027 MCP Server Write-Tools Technical Preview|x64/RMCP/RMCP.msi|publicmcpserver/PublicMcpServer.exe|{A2B3C4D5-2701-0010-4804-C5384500AB01}"
  "revitmcp-experimental|Revit 2027 MCP Server Experimental-Tools Technical Preview|x64/RMCE/RMCE.msi|publicmcpserver/PublicMcpServerExperimental.exe|{A4B5C6D7-2701-0010-4804-C5384500AB01}"
)
MCP_SERVER_EXE=Autodesk.RevitMcpServer.Stdio.exe
MCP_NOTICE="Autodesk's MCP Server is a Technical Preview and runs only with Autodesk analytics (ADP); installing it turns ADP on in this bottle."

mcp_field() { # $1 = id, $2 = column (1 = id … 5 = ProductCode); 1 = no such variant
  local v; for v in "${MCP_VARIANTS[@]}"; do
    [ "${v%%|*}" = "$1" ] && { printf '%s\n' "$v" | cut -d'|' -f"$2"; return 0; }
  done
  return 1
}
mcp_folder()   { local f; f="$(mcp_field "$1" 2)" && echo "$B/drive_c/Program Files/Autodesk/$f"; }   # $1 = id
mcp_manifest() { echo "$B/drive_c/Program Files/Autodesk/Revit/Addins/$YEAR/Autodesk.RevitMcpServer.addin"; }
mcp_adp_marker() { echo "$B/drive_c/ProgramData/revit-macos/adp"; }   # the ADP package version, after a complete install
mcp_adp_core() { echo "$B/drive_c/Program Files/Common Files/Autodesk/AdpDesktopSDK/bin/AdpSDKCore.dll"; }
mcp_dist() { revit_dist "$YEAR"; }   # the unpacked Revit installer: ADP comes from there
mcp_adp_version() { # the ADP package version of the unpacked installer; nothing and 1 when it is not there
  local v; v="$(sed -n 's:.*<BuildNumber>\([^<]*\)</BuildNumber>.*:\1:p' "$(mcp_dist)/x64/AdpSdk/pkg.adp-desktop-sdk.xml" 2>/dev/null | head -1)"
  [ -n "$v" ] && echo "$v"
}
mcp_installed_variant() { # the variant the add-in manifest points at (its <Assembly> folder); nothing when none or unknown
  local a v f; a="$(sed -n 's:.*<Assembly>\(.*\)\\[^\\]*</Assembly>.*:\1:p' "$(mcp_manifest)" 2>/dev/null | tr -d '\r' | head -1)"
  [ -n "$a" ] || return 0
  for v in "${MCP_VARIANTS[@]}"; do
    f="$(printf '%s\n' "$v" | cut -d'|' -f2)"
    [ "$a" = "C:\\Program Files\\Autodesk\\$f" ] && { echo "${v%%|*}"; return 0; }
  done
  return 0
}
mcp_missing() { # $1 = id: the first piece that is missing, as a short phrase; nothing when the variant is ready
  local d; d="$(mcp_folder "$1")" || { echo "an unknown MCP Server variant"; return 0; }
  if [ ! -f "$d/$MCP_SERVER_EXE" ]; then echo "the MCP Server files"
  elif [ ! -f "$(mcp_manifest)" ]; then echo "the MCP add-in manifest"
  elif [ "$(mcp_installed_variant)" != "$1" ]; then echo "an add-in manifest for this variant"
  elif [ ! -f "$d/mcphost.exe" ]; then echo "mcphost.exe"
  elif [ ! -f "$d/mcppipes.dll" ]; then echo "mcppipes.dll"
  elif ! cmp -s "$d/mcphost.exe" "$(shim_dir)/mcphost/mcphost.exe"; then echo "the current mcphost.exe"
  elif ! cmp -s "$d/mcppipes.dll" "$(shim_dir)/mcppipes/mcppipes.dll"; then echo "the current mcppipes.dll"
  elif [ ! -s "$(mcp_adp_marker)" ] || [ ! -f "$(mcp_adp_core)" ]; then echo "Autodesk analytics (ADP)"
  fi
  return 0
}
mcp_ready() { [ -z "$(mcp_missing "$1")" ]; }   # $1 = id
mcp_product_registered() { # $1 = id: its MSI is registered, asked of the running wineserver (system.reg on disk lags
  # behind by up to half a minute). Needs wine.sh
  w reg query "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$(mcp_field "$1" 5)" >/dev/null 2>&1
}

# pyRevit's agent (./revit mcp --server pyrevit): its MCP server is pyrevit.exe mcp, started through our mcphost.exe
# --plain. Files only, as above. tools/doctor.py holds the same paths and ini rules (PYREVIT_* there)
PYREVIT_CLONE_REL="drive_c/users/crossover/AppData/Roaming/pyRevit-Master"
PYREVIT_CONFIG_REL="drive_c/users/crossover/AppData/Roaming/pyRevit/pyRevit_config.ini"
PYREVIT_INSTANCES_REL="drive_c/users/crossover/AppData/Roaming/pyRevit/agent/instances"
PLAIN_HOST_REL="drive_c/ProgramData/revit-macos/mcphost/mcphost.exe"   # C:\ProgramData\revit-macos\mcphost\mcphost.exe
pyrevit_agent_enabled() { # $1 = pyRevit_config.ini: 0 when its [agent] section says enabled = true (any case; pyRevit
  # writes Windows line ends)
  tr -d '\r' < "$1" 2>/dev/null | awk '
    /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); agent = (tolower(s) == "[agent]"); next }
    agent { k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); v = $0; if (!sub(/^[^=]*=/, "", v)) next
            gsub(/[[:space:]]/, "", v); if (tolower(k) == "enabled") on = (tolower(v) == "true") }
    END { exit !on }'
}
pyrevit_agent_policy() { # readonly, ask or auto from [agent] in pyRevit_config.ini; nothing when there is none
  { tr -d '\r"' < "$B/$PYREVIT_CONFIG_REL"; } 2>/dev/null | awk '
    /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); agent = (tolower(s) == "[agent]"); next }
    agent { k = $0; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k); v = $0; if (!sub(/^[^=]*=/, "", v)) next
            gsub(/[[:space:]]/, "", v); if (tolower(k) == "policy") p = tolower(v) }
    END { print p }'
}
pyrevit_mcp_missing() { # $1 = year: the first missing piece, nothing when ready: not-offered (this project has no
  # pyRevit for the year), no-agent-runtime (the year's or the installed pyRevit is before 7), not-installed, agent-off,
  # not-registered (the agent has no instance file: not running in Revit). An instance file left by an ended Revit
  # passes; pyrevit.exe has the last word then (its tools answer no_revit)
  addin_load pyrevit
  local v; v="$(pyrevit_version_offered "$1")"
  if [ -z "$(addin_files "$1")" ]; then echo not-offered
  elif [ "${v%%.*}" -lt 7 ] 2>/dev/null; then echo no-agent-runtime   # the year's pyRevit has none: no use installing it
  elif [ ! -d "$B/$PYREVIT_CLONE_REL" ]; then echo not-installed
  elif [ ! -f "$B/$PYREVIT_CLONE_REL/pyrevitlib/pyrevit/agent/_runner.py" ]; then echo no-agent-runtime
  elif ! pyrevit_agent_enabled "$B/$PYREVIT_CONFIG_REL"; then echo agent-off
  elif ! ls "$B/$PYREVIT_INSTANCES_REL"/*.json >/dev/null 2>&1; then echo not-registered
  fi
  return 0
}
pyrevit_version_offered() { # $1 = year: major.minor of the pyRevit this project installs for it (4.8, 7.0)
  addin_load pyrevit; addin_files "$1" | cut -f2 | sed -n 's/.*pyRevit_\([0-9]*\.[0-9]*\).*/\1/p' | head -1
}
plain_host_ensure() { # our mcphost.exe for --plain in the bottle, equal to $(shim_dir)/mcphost/mcphost.exe afterwards:
  # written only when missing or different, through a temporary file beside it (a running copy is not touched).
  # Under the lock. Needs shims.sh. 1 with the reason on stdout
  local src t="$B/$PLAIN_HOST_REL" out
  out="$(ensure_shim mcphost 2>&1)" || { tail -1 <<<"$out"; return 1; }
  src="$(shim_dir)/mcphost/mcphost.exe"; [ -f "$src" ] || { echo "no $src"; return 1; }
  cmp -s "$src" "$t" && return 0
  mkdir -p "$(dirname "$t")" && cp "$src" "$t.tmp.$$" && mv -f "$t.tmp.$$" "$t" || { rm -f "$t.tmp.$$"; echo "cannot write $t"; return 1; }
}
mcp_server_row() { # $1 = id, $2 = name in words, $3 = missing, $4 = what only a connection shows, $5.. = gate arguments:
  # one object of ./revit mcp servers
  local id="$1" n="$2" miss="$3" note="$4" st=ready; shift 4; [ -z "$miss" ] || st=missing
  printf '{"id":%s,"name":%s,"state":%s,"missing":%s,"note":%s,%s' "$(json_str "$id")" "$(json_str "$n")" "$(json_str "$st")" \
    "$(json_str "$miss")" "$(json_str "$note")" "$(python3 -I -B "$ROOT/tools/mcp_gate.py" server-info "$@" --server "$id" | sed 's/^{//')"
}
mcp_servers_json() { # the servers of $YEAR in bottle $B for the app: files and settings only, no Wine, nothing changes.
  # What depends on a running Revit is said in note: the launch checks it when an assistant connects
  local rows=() m g=(--root "$ROOT" --data "$DATA" --year "$YEAR" --bottle "$NAME") open="Revit $YEAR must be open with a model when the assistant connects."
  [ "$(mcp_installed_variant)" != revitmcp-experimental ] || g+=(--experimental)
  addin_load revitmcp
  if addin_available; then
    ID="$(mcp_installed_variant)"; m=""
    if [ -z "$ID" ]; then m="Install it on the Add-ins tab."
    elif ! mcp_ready "$ID"; then m="Install it again on the Add-ins tab: $(mcp_missing "$ID") is missing."; fi
    rows+=("$(mcp_server_row autodesk "Autodesk Revit MCP Server" "$m" "$open" "${g[@]}")")
  fi
  m="$(pyrevit_mcp_missing "$YEAR")"
  case "$m" in
    not-offered|no-agent-runtime) ;;
    not-installed) rows+=("$(mcp_server_row pyrevit "pyRevit's agent" "Install pyRevit on the Add-ins tab." "$open" "${g[@]}")") ;;
    agent-off) rows+=("$(mcp_server_row pyrevit "pyRevit's agent" "In Revit: pyRevit, Settings, Agent Runtime, turn on Agent Host, then reload pyRevit." "$open" "${g[@]}")") ;;
    *) rows+=("$(mcp_server_row pyrevit "pyRevit's agent" "" "$open pyRevit's agent must be running in it." "${g[@]}")") ;;
  esac
  addin_load python-mcp
  if addin_available; then
    m=""; addin_is_installed || m="Install it on the Add-ins tab."
    rows+=("$(mcp_server_row python "MCP server for Revit (Python)" "$m" "$open In Revit: MCP, Bridge, Connect." "${g[@]}")")
  fi
  if [ "$YEAR" = 2027 ]; then
    m=""; [ -f "$(shim_dir)/uibridge/uibridge.exe" ] || m="A file this app needs is missing. Get the app again."
    rows+=("$(mcp_server_row ui "Revit's windows" "$m" "Revit $YEAR must be open when the assistant connects." "${g[@]}")")
  fi
  local IFS=,
  printf '{"command":"mcp-servers","year":%s,"bottle":%s,"servers":[%s]}\n' "$((10#$YEAR))" "$(json_str "$NAME")" "${rows[*]}"
}
ui_commands_extension() { # $1 = year, $2 = bottle: puts tools/revitmacos-ui.extension into the bottle's pyRevit; from the
  # next start of Revit on it writes the command table of each new build (./revit mcp --server ui)
  local year="$1" name="$2" b ext sfx; b="$(bottle_path "$name")"; sfx="$(bottle_sfx "$name" "$year")"
  ext="$b/$PYREVIT_CLONE_REL/extensions/revitmacos-ui.extension"
  [ -d "$b/$PYREVIT_CLONE_REL/extensions" ] || die "pyRevit is not installed in $name. Install it: ./revit addins $year$sfx --only pyrevit"
  rm -rf "$ext.new"; cp -R "$ROOT/tools/revitmacos-ui.extension" "$ext.new" || die "Cannot write to $(tilde "$ext")."
  rm -rf "$ext"; mv "$ext.new" "$ext" || die "Cannot write to $(tilde "$ext")."
  if revit_running "$b" "$year"; then echo "Quit Revit and start it again: it then writes the command table."
  else echo "The command table appears the next time Revit starts."; fi
}
ui_revit_pid() { # the one Revit.exe of this bottle: revit_pids also lists the CrossOver loader that started it
  local p pids=()
  for p in $(revit_pids "$B" "$YEAR"); do
    ps -o command= -p "$p" 2>/dev/null | grep -q winewrapper || pids+=("$p")
  done
  [ ${#pids[@]} = 1 ] || die "More than one Revit $YEAR runs in $NAME."
  echo "${pids[0]}"
}
agent_view() { # B, YEAR, NAME: gives the running Revit a bundle ID. Computer use tools list apps by it, and Revit under Wine
  # has none. Only this process has it, until it ends; no file changes
  local pid asn id="local.revit-macos.revit-live-$NAME"
  revit_running "$B" "$YEAR" || die "Open Revit $YEAR first."
  pid="$(ui_revit_pid)" || exit 1
  asn="$(lsappinfo find "pid=$pid")"
  [ -n "$asn" ] || die "Could not find Revit in Launch Services."
  lsappinfo setinfo "$asn" "CFBundleIdentifier=$id" || die "Could not give Revit its ID."
  case "$(lsappinfo info -only bundleid "$asn")" in
    *"\"$id\""*) ;;
    *) die "Could not give Revit its ID." ;;
  esac
  echo "Revit is now visible to computer use tools as $id, until it quits."
}
