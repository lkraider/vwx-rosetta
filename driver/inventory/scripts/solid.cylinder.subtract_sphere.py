# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.cylinder.subtract_sphere
# family_id: solid.csg
# recipe_revision: 1
# recipe_path: recipes/solid.cylinder.subtract_sphere.json
# recipe_sha256: b9384cb6860399ff61b241095940434e7e53b5234a5404415c37a6d0b9d3258e
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginXtrd(0, 18.5)
vs.Oval((3.5, 21.25), (17.75, 7))
vs.EndXtrd()
h_cy = vs.LNewObj()
vs.SetName(h_cy, "cylinder-a")
h_sp = vs.CreateSphere((12.25, 15.5, 18.5), 5.5)
vs.SetName(h_sp, "sphere-b")
rosetta_checkpoint("before-boolean")
h_res = vs.SubtractSolid(h_cy, h_sp)[1]
vs.SetName(h_res, "csg-subtract")
rosetta_save_reopen()
