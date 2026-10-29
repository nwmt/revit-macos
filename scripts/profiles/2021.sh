# Revit 2021: ODIS installer (an app.*.xml per package), Revit itself in RVT.msi, .NET Framework 4.8, sign-in in
# Revit's own window (AdSSO). Draft: not yet run end to end.
INSTALLER=odis
DOTNET=netfx48
PRODKEY=829M1
SIGNIN=adsso
LICENSING_OK="64"                  # AdskLicensing 10.2: takeown and `sc sdshow` fail under Wine (LIC-INST-ERROR-320)
STEPS=(netfx vc fonts licensing svcshim adsso rvt pkgs register ncryptshim ssoenv wbemshim richedit d3d9dxvk warpshim
  gdoff rvtfix tlbpin dynamo wpfsw samples gdrive)
# core ODIS packages (names from manifest/app.RVT.xml): no FormIt, MEP Fabrication, other languages
PKGS="RCLC|RCLCRVT|CM2021|CMILB2021|PrismBaseImageLibrary2021|PrismLowImageLibrary2021|UNITSCHEMAS|RCLEENU|RET|GenerativeDesign"
REVITINI=()
THEME=0
RICHEDIT=(riched20 usp10 msls31)
RVTFIX_ENV=(RVTFIX_CEF_ARGS=)      # rvtfix's CefSharp flag is off, as on 2020
DYNAMO=2.6
ADDIN_STEPS=()
LOOKUP=""
PYREVIT=""
PYREVIT_ATTACH=""
ENSCAPE=""
