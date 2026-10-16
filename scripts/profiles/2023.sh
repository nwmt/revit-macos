# Revit 2023: ODIS installer, Revit itself in RVT.msi, .NET Framework 4.8, sign-in in Revit's own window (AdSSO).
INSTALLER=odis
DOTNET=netfx48
PRODKEY=829O1
SIGNIN=adsso
LICENSING_OK="84"                  # its service cannot start under Wine before the svcshim step
STEPS=(vc fonts netfx licensing svcshim adsso rvt pkgs register ncryptshim ssoenv wbemshim d3d9dxvk richedit tlbpin
  warpshim gdoff rvtfix dynamo)
# core ODIS packages (names from manifest/app.RVT.xml): no Dynamo, Twinmotion, other languages; materials CM2023/…2023
PKGS="RCLC|RCLCRVT|RVTCPSTLCON|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM2023|CMILB2023|PrismBaseImageLibrary2023|PrismLowImageLibrary2023|PrismMediumImageLibrary2023|UNITSCHEMAS|RCLEENU|RET|GenerativeDesign"
REVITINI=()
THEME=0
RICHEDIT=(msftedit riched20 usp10 msls31)
RVTFIX_ENV=()
DYNAMO=2.13
ADDIN_STEPS=(revitlookup pyrevit trust wpfsw check)
LOOKUP=revitlookup/RevitLookup-2023.5.4-SingleUser.msi     # GitHub release 2027.0.4
PYREVIT=pyrevit7/pyRevit_7.0.0.26278_signed.exe
PYREVIT_ATTACH=""
ENSCAPE=""
