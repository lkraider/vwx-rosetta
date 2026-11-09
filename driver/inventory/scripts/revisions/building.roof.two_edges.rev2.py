# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: building.roof.two_edges
# family_id: building.roof
# recipe_revision: 2
# base: driver/inventory/scripts/building.roof.two_edges.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/building.roof.two_edges.vwx
#   sha256 345a6aecac0572ef1c36563070e8888fc1acd704a53f1b995b6b4d094c517179. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_rf = vs.CreateRoof(False, 0, 12.5, 1, 0)
vs.SetName(h_rf, "roof-a")
vs.AppendRoofEdge(h_rf, (5, 2.5), 32.5, 18, 240)
vs.AppendRoofEdge(h_rf, (415.5, 2.5), 40, 18, 240)
vs.AppendRoofEdge(h_rf, (415.5, 260.75), 90, 0, 240)
vs.AppendRoofEdge(h_rf, (5, 198), 90, 0, 240)
vs.ResetObject(h_rf)
rosetta_save_reopen()
