#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Turn off Dynamo's hardware acceleration and its background 3D preview; keep the preview in Revit views.

  dynamo_settings.py <DynamoSettings.xml>

Dynamo's 3D preview (HelixToolkit.SharpDX) breaks under D3DMetal: a crash in 2020 (GetSharedHandle → E_NOTIMPL),
black squares and lag across Revit in 2023. Dynamo writes the file on its first run and on exit; a missing file gets
a minimal one. Run with Revit closed, with python3 -I.
"""
import os
import sys
import xml.etree.ElementTree as ET


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    if os.path.exists(path):
        tree = ET.parse(path)
        root = tree.getroot()
    else:
        root = ET.Element("PreferenceSettings")
        tree = ET.ElementTree(root)
        ET.SubElement(root, "IsFirstRun").text = "false"
    e = root.find("UseHardwareAcceleration")
    if e is None:
        e = ET.SubElement(root, "UseHardwareAcceleration")
    e.text = "false"
    previews = root.find("BackgroundPreviews")
    if previews is None:
        previews = ET.SubElement(root, "BackgroundPreviews")
    states = {s.findtext("Name"): s for s in previews.findall("BackgroundPreviewActiveState")}
    for name, value in (("IsBackgroundPreviewActive", "false"), ("IsRevitBackgroundPreviewActive", "true")):
        s = states.get(name)
        if s is None:
            s = ET.SubElement(previews, "BackgroundPreviewActiveState")
            ET.SubElement(s, "Name").text = name
            ET.SubElement(s, "IsActive")
        s.find("IsActive").text = value
    tree.write(path, xml_declaration=True, encoding="utf-8")
    print("ok", path)


if __name__ == "__main__":
    main()
