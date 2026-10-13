# Revit 2025: ODIS installer, .NET 8 (the 2025.5 update adds .NET 10; both get installed), sign-in in the browser.
INSTALLER=odis
DOTNET=net8
PRODKEY=829Q1
SIGNIN=idmgr
LICENSING_OK="84"
STEPS=(vc fonts dotnet licensing svcshim idmgr rvt pkgs asc revitini register ncryptshim webview2 d3d9dxvk richedit
  tlbpin warpshim gdoff rvtfix wv2fix pdfprinter dynamo)
# like 2026 without OpenUSD; adds RSA Interop and CEFSHARP (CefSharp, as in 2023); no ASC package; Dynamo 3.3 (ADIX)
PKGS="RCLC|RCLCRVT|RVTCPSTLCON|HIVE|DWGSHARED|REX Framework|REX Revit|RSA CommonData|RSA COM|RSA Interop|RSA RoReinf|CM4|CMILB4|PrismBaseImageLibrary4|PrismLowImageLibrary4|PrismMediumImageLibrary4|UNITSCHEMAS|RCLEENU|ATF|CORE|CLOUD|SHARED|RVTONLY|CEFSHARP|RET|GenerativeDesign|DYNAMO_CORE|DYNAMO_DOCS"
REVITINI=(Language.Select=ENU 'Interoperability.RealDWGInstalledLocation=C:\Program Files\Autodesk\RealDWG Shared 2025\')
THEME=1
RICHEDIT=(msftedit riched20 usp10 msls31)
RVTFIX_ENV=()
DYNAMO=3.3
ADDIN_STEPS=(revitlookup pyrevit trust wpfsw check)
LOOKUP=revitlookup/RevitLookup-2025.2.4-SingleUser.msi     # GitHub release 2027.0.4
PYREVIT=pyrevit7/pyRevit_7.0.0.26278_signed.exe
PYREVIT_ATTACH=""
ENSCAPE=""
