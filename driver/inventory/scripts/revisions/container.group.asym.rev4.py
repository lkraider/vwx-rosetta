# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: container.group.asym
# family_id: container.group
# recipe_revision: 4
# base: driver/inventory/scripts/revisions/container.group.asym.rev3.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/container.group.asym.vwx
#   sha256 ff030310c1f64b647b455d26e0550cd0e7c952d9a0b10fab040e029a887f9dd0. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginGroup()
vs.Rect((4.5, 18.25), (27, 2))
h_gr = vs.LNewObj()
vs.SetName(h_gr, "grp-rect")
vs.Oval((21.5, 31), (39.75, 14.5))
h_go = vs.LNewObj()
vs.SetName(h_go, "grp-oval")
vs.BeginXtrd(0, 3.5)
vs.Rect((30, 12), (44.5, 3.5))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'grp-mesh')
vs.EndGroup()
h_g = vs.LNewObj()
vs.SetName(h_g, "group-a")
rosetta_save_reopen()
