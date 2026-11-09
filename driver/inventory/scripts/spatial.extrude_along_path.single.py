# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: spatial.extrude_along_path.single
# family_id: spatial.extrude_along_path
# recipe_revision: 1
# recipe_path: recipes/spatial.extrude_along_path.single.json
# recipe_sha256: 0f2af6651b43e57b9b15c1decfb9766d3cdfcbeded104653357bb8331ccdfd78
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_pa = vs.CreateNurbsCurve((0, 0, 0), True, 2)
vs.SetName(h_pa, "path-a")
vs.AddVertex3D(h_pa, (2000, 1000, 0))
vs.AddVertex3D(h_pa, (4000, 0, 0))
vs.Oval((-50, 50), (50, -50))
h_pr = vs.LNewObj()
vs.SetName(h_pr, "profile-a")
h_ep = vs.CreateExtrudeAlongPath(h_pa, h_pr)
vs.SetName(h_ep, "extrude-path-a")
rosetta_save_reopen()
