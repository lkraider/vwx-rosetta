# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: spatial.floor.legacy
# family_id: spatial.floor
# recipe_revision: 1
# recipe_path: recipes/spatial.floor.legacy.json
# recipe_sha256: a88ca260a60aed42fa04041a24b407872825372aae5d181319106b473852bf33
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginFloor(200)
vs.Rect((0, 3000), (4000, 0))
vs.EndGroup()
h_fl = vs.LNewObj()
vs.SetName(h_fl, "floor-a")
rosetta_save_reopen()
