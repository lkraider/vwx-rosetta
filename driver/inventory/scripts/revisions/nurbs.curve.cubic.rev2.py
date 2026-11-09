# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: nurbs.curve.cubic
# family_id: nurbs.curve
# recipe_revision: 2
# base: driver/inventory/scripts/nurbs.curve.cubic.py
# native_verification: executed: driver/ui/make-sources.py batch 6, commit 73a2296, wrote sources/nurbs.curve.cubic.vwx
#   sha256 43039c6cf74279cfd40de8c1d98f6cff65b4a83df6f77fd7e05bdd1438fcb682. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_nc = vs.CreateNurbsCurve((2.5, 1.25, 0.5), True, 3)
vs.SetName(h_nc, "nurbs-curve-a")
vs.AddVertex3D(h_nc, (14.75, 9.5, 3.25))
vs.AddVertex3D(h_nc, (27, -4.25, 7.5))
vs.AddVertex3D(h_nc, (41.5, 12, 1.75))
vs.AddVertex3D(h_nc, (53.25, 3.5, 11))
vs.NurbsSetWeight(h_nc, 0, 2, 2.75)
vs.BeginXtrd(0, 3.5)
vs.Rect((2.5, -8), (15.25, -14.5))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'mesh-a')
rosetta_save_reopen()
