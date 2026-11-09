# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: building.wall.with_door_window
# family_id: building.wall
# recipe_revision: 1
# recipe_path: recipes/building.wall.with_door_window.json
# recipe_sha256: 141d0c658ab4f0c0248e52681ea244b5ecc0fd3f8620c4871e23bb33c7d5a4db
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSym("Rosetta-Door-Sym")
h_dp = vs.CreateCustomObject("Door", (0, 0), 0)
vs.SetName(h_dp, "door-in-symbol")
vs.EndSym()
vs.BeginSym("Rosetta-Window-Sym")
h_wp = vs.CreateCustomObject("Window", (0, 0), 0)
vs.SetName(h_wp, "window-in-symbol")
vs.EndSym()
vs.Wall((10.5, 4.25), (5212, 97.75))
h_w = vs.LNewObj()
vs.SetName(h_w, "wall-inserts")
vs.AddSymToWall(h_w, 1350, 0, False, False, "Rosetta-Door-Sym")
vs.AddSymToWall(h_w, 3725, 900, False, False, "Rosetta-Window-Sym")
rosetta_save_reopen()
