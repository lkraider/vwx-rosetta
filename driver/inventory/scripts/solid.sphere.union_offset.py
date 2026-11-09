# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.sphere.union_offset
# family_id: solid.csg
# recipe_revision: 1
# recipe_path: recipes/solid.sphere.union_offset.json
# recipe_sha256: c13bcdae0006e4951cc1e6d8842c4adbfddf24e75b5344a4c7205be14f373dd8
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_sa = vs.CreateSphere((12.5, 8.25, 3), 6.75)
vs.SetName(h_sa, "sphere-a")
h_sb = vs.CreateSphere((19.75, 11.5, 5.5), 4.25)
vs.SetName(h_sb, "sphere-b")
rosetta_checkpoint("before-boolean")
h_res = vs.AddSolid(h_sa, h_sb)[1]
vs.SetName(h_res, "csg-add")
rosetta_save_reopen()
