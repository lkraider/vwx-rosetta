# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: building.wall.joined_l_t
# family_id: building.wall
# recipe_revision: 1
# recipe_path: recipes/building.wall.joined_l_t.json
# recipe_sha256: b207ce121df26b4238c2bd3b4f68bd2ecf49f6a89aac1ccecb57f040c99e7e00
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Wall((0, 0), (4000, 0))
h_wa = vs.LNewObj()
vs.SetName(h_wa, "wall-a")
vs.Wall((4000, 0), (4000, 3000))
h_wb = vs.LNewObj()
vs.SetName(h_wb, "wall-b")
vs.Wall((1750, 3000), (1750, 0))
h_wc = vs.LNewObj()
vs.SetName(h_wc, "wall-c")
vs.JoinWalls(h_wa, h_wb, (3900, 0), (4000, 100), 2, False, False)
vs.JoinWalls(h_wc, h_wa, (1750, 100), (1500, 0), 1, False, False)
rosetta_save_reopen()
