# Rosetta fixture recipe written in this repository for ROADMAP G3, BIM objects.
# case_id: building.stair.simple
# family_id: building.stair
# recipe_revision: 1
# recipe_path: recipes/building.stair.simple.json
# recipe_sha256: b732907f759e57d7225cff25e00cc08b2c9983432b1121bd6f7d704f99a72ed6
# native_verification: executed: driver/ui/make-sources.py batch g3-bim, commit db6e0bf, wrote sources/building.stair.simple.vwx
#   sha256 e83957406dee44a392e6ea9a7cb44ab657592ce35ca090361eac2d4d078c721a. Run 20261018T124746-script-stl exported that source.
# The capture adapter defines rosetta_checkpoint(id), rosetta_menu(*path) and rosetta_save_reopen() before running this file.
import vs
h_st = vs.CreateCustomObject("Simple Stair", (0, 0), 0)
vs.SetName(h_st, "stair-a")
vs.ResetObject(h_st)
rosetta_save_reopen()
