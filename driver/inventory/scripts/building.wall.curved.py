# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: building.wall.curved
# family_id: building.wall
# recipe_revision: 1
# recipe_path: recipes/building.wall.curved.json
# recipe_sha256: a06d070f9ad954a5cbfcc952bb17c8cbc1f46872a0aff5c6c38193f259fba529
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.RoundWall((2250, 750), (4750, 750), (2250, 3250))
h_w = vs.LNewObj()
vs.SetName(h_w, "wall-round")
rosetta_save_reopen()
