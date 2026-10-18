# Revit 2027: ODIS installer, .NET 10, sign-in in the browser.
# Enscape 4.18 LTS with its fixes: scripts/run-steps.sh 2027 <bottle> enscape trust.
INSTALLER=odis
DOTNET=net10
PRODKEY=829S1
SIGNIN=idmgr
LICENSING_OK="84"
STEPS=(vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk richedit
  tlbpin warpshim gdoff rvtfix wv2fix downloads)
# materials v5, ENU content split into Imperial/Metric, core is CORE+COREADD+COREEXT, sample projects in RCLRVTSMPL;
# no RET, RSA RoReinf, Generative Design
PKGS="RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|CM5|CMILB5|PrismBaseImageLibrary5|PrismLowImageLibrary5|PrismMediumImageLibrary5|UNITSCHEMAS|UNITSCHEMASLOCALE|RCLEENUI|RCLEENUM|ATF|CORE|COREADD|COREEXT|CLOUD|SHARED|SHAREDRENDER|RVTONLY|RVTONLY_CLOUD|OpenUSD|Addins Manager|RCLRVTSMPL"
REVITINI=(Language.Select=ENU)
THEME=1
RICHEDIT=(msftedit riched20 usp10 msls31)
RVTFIX_ENV=()
DYNAMO=""
ADDIN_STEPS=(revitlookup pyrevit trust wpfsw check)
ADDIN_WPF_SW=1                     # add-in windows need software WPF (step wpfsw)
LOOKUP=revitlookup/RevitLookup-2027.0.4-SingleUser.msi
PYREVIT=pyrevit7/pyRevit_7.0.0.26278_signed.exe
PYREVIT_ATTACH=""
ENSCAPE=4
