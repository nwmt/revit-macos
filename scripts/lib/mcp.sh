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
mcp_dist() { echo "$DATA/installers/extracted/revit$YEAR"; }   # the unpacked Revit installer: ADP comes from there
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
