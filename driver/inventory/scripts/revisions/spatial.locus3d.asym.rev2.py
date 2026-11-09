# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: spatial.locus3d.asym
# family_id: spatial.locus3d
# recipe_revision: 2
# base: driver/inventory/scripts/spatial.locus3d.asym.py
# native_verification: executed: driver/ui/make-sources.py batch 1, commit 73a2296, wrote sources/spatial.locus3d.asym.vwx
#   sha256 5a07fabfaaac45186cc123d4935829bcf0a298524b2abc848494115717ddf956. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Locus3D((21.5, -8.75, 13.25))
h_l3 = vs.LNewObj()
vs.SetName(h_l3, "locus3d-a")
vs.BeginXtrd(0, 3.5)
vs.Rect((17, -4.5), (28.25, -12))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'mesh-a')
rosetta_save_reopen()
