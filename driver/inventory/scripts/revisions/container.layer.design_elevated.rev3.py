# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: container.layer.design_elevated
# family_id: container.layer
# recipe_revision: 3
# base: driver/inventory/scripts/container.layer.design_elevated.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/container.layer.design_elevated.vwx
#   sha256 04b94b176dc65d0ca258bacd0edef1419e49c13978fff66ea6bf08b79a53be85. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.CreateLayer("Rosetta-Layer-Elev", 1)
vs.SetName(h_ly, "Rosetta-Layer-Elev")
vs.SetLayerElevation(h_ly, 1250.5, 310.25)
vs.Layer("Rosetta-Layer-Elev")
vs.Rect((6.5, 21), (38.25, 3.75))
h_r = vs.LNewObj()
vs.SetName(h_r, "rect-on-layer")
vs.BeginXtrd(0, 3.5)
vs.Rect((42, 18.5), (55.25, 6))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'mesh-on-layer')
rosetta_save_reopen()
