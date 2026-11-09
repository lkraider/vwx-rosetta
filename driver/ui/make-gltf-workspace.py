"""Write a copy of a Vectorworks workspace that adds the glTF export item to File > Export.

Usage: python3 make-gltf-workspace.py SOURCE.vww OUT.vww

The store's glTF exports used SOURCE = the shipped `Workspaces/Architect.vww` of Vectorworks 2027 and
OUT = `~/Library/Application Support/Vectorworks/2027/Workspaces/Rosetta glTF.vww`.
"""
import sys

src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
anchor = "        <net.vectorworks.workspaceitem.menuitem.FBX_x20Export/>\n"
assert s.count(anchor) == 1, "FBX item in the Export submenu not found once"
s = s.replace(anchor, anchor + "        <net.vectorworks.workspaceitem.menuitem.Gltf_x20Export/>\n")
item = "    </net.vectorworks.workspaceitem.menuitem.FBX_x20Export>\n"
assert s.count(item) == 1
s = s.replace(item, item + (
    "    <net.vectorworks.workspaceitem.menuitem.Gltf_x20Export>\n"
    "      <ResourceManagerID>358</ResourceManagerID>\n"
    "      <UniversalName>Gltf_x20Export</UniversalName>\n"
    "    </net.vectorworks.workspaceitem.menuitem.Gltf_x20Export>\n"))
with open(out, "x", encoding="utf-8") as f:
    f.write(s)
