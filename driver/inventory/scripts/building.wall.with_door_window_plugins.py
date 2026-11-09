# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: building.wall.with_door_window_plugins
# family_id: building.wall
# recipe_revision: 1
# recipe_path: recipes/building.wall.with_door_window_plugins.json
# recipe_sha256: fdcdd065e8355ac19bb378fcb67f6ec643aee54a638aa76c5a251a148b52cac5
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Wall((0, 0), (5200, 0))
h_w = vs.LNewObj()
vs.SetName(h_w, "wall-inserts")
vs.AddSymToWall(h_w, 1350, 0, False, False, "Door")
h_dp = vs.LNewObj()
vs.SetName(h_dp, "door-in-wall")
vs.AddSymToWall(h_w, 3725, 900, False, False, "Window")
h_wp = vs.LNewObj()
vs.SetName(h_wp, "window-in-wall")
rosetta_save_reopen()
