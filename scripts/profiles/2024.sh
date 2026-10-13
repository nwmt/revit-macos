# Revit 2024: ODIS installer, Revit in RVT.msi plus the update's RVTSP*.msp, .NET Framework 4.8 as 2023;
# sign-in in the browser (AdskIdentityManager), WebView2 and RealDWG as 2025.
INSTALLER=odis
DOTNET=netfx48
PRODKEY=829P1
SIGNIN=idmgr
LICENSING_OK="84"
STEPS=(vc fonts netfx licensing svcshim idmgr rvt pkgs revitini register ncryptshim webview2 wbemshim d3d9dxvk richedit
  tlbpin warpshim gdoff rvtfix wv2fix pdfprinter dynamo)
# the rest of Revit (CefSharp, ATF, shared and cloud parts with Dynamo) is in the MSM_* ADIX packages
PKGS="RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|MSM_CEFSHARP|MSM_ATF|MSM_EXT|MSM_CLOUD|RET|GenerativeDesign"
# RealDWG: Revit finds it through the HIVE host, which asks ODIS's install database; it reads this cached path first
REVITINI=(Language.Select=ENU 'Interoperability.RealDWGInstalledLocation=C:\Program Files\Autodesk\RealDWG Shared 2024\')
THEME=1
RICHEDIT=(msftedit riched20 usp10 msls31)
RVTFIX_ENV=()
DYNAMO=2.19
ADDIN_STEPS=(revitlookup pyrevit trust wpfsw check)
LOOKUP=revitlookup/RevitLookup-2024.3.4-SingleUser.msi     # GitHub release 2027.0.4
PYREVIT=pyrevit7/pyRevit_7.0.0.26278_signed.exe
PYREVIT_ATTACH=""
ENSCAPE=""
