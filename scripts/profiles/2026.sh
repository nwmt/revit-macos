# Revit 2026: ODIS installer, .NET 8 (the 2026.5 update adds .NET 10 and ships the runtime; both get installed).
INSTALLER=odis
DOTNET=net8
PRODKEY=829R1
SIGNIN=idmgr
LICENSING_OK="84"
STEPS=(vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk richedit
  tlbpin warpshim gdoff rvtfix wv2fix)
PKGS="RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|ATF|CORE|CLOUD|SHARED|RVTONLY|RET|OpenUSD|GenerativeDesign"
REVITINI=(Language.Select=ENU)
THEME=1
RICHEDIT=(msftedit riched20 usp10 msls31)
RVTFIX_ENV=()
DYNAMO=""
ADDIN_STEPS=(revitlookup pyrevit trust wpfsw check)
LOOKUP=revitlookup/RevitLookup-2026.1.4-SingleUser.msi
PYREVIT=pyrevit7/pyRevit_7.0.0.26278_signed.exe
PYREVIT_ATTACH=""
ENSCAPE=""
