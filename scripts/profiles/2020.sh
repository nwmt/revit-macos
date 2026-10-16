# Revit 2020: Setup.ini installer (multi-part download), .NET Framework 4.7, sign-in in Revit's own window (AdSSO).
INSTALLER=setupini
DOTNET=netfx47                     # the installer's 4.7; 4.7.2 and 4.8 crash Revit 2020 under Wine
PRODKEY=829L1
SIGNIN=adsso
LICENSING_OK="1"                   # the licensing installer's takeown and `sc sdshow` fail under Wine
STEPS=(netfx vc fonts licensing svcshim adsso rcl rvt ret materials register ncryptshim ssoenv wbemshim richedit dynamo
  d3d9dxvk warpshim rvtfix tlbpin samples)
PKGS=""
REVITINI=()
THEME=0
RICHEDIT=(riched20 usp10 msls31)
RVTFIX_ENV=(RVTFIX_CEF_ARGS=)      # rvtfix's CefSharp flag is off: never tried on 2020's CefSharp panels
DYNAMO=2.3
ADDIN_STEPS=(revitlookup pyrevit trust check)
LOOKUP=revitlookup/RevitLookup-2020.0.0.3-SingleUser.msi   # last build for 2020 (release 2023.1.0-EOL)
PYREVIT=pyrevit48/pyRevit_4.8.12.22247_signed.exe          # its IPY277 engine runs on .NET 4.7 (6.5.5 does not)
PYREVIT_ATTACH=277                 # the installer does not find Revit 2020: attach explicitly
ENSCAPE=3
