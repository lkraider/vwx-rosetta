# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: building.stair.custom
# family_id: building.stair
# recipe_revision: 1
# recipe_path: recipes/building.stair.custom.json
# recipe_sha256: 8fa0b029466ef5bed29a8bd0cb0e58713739089d4094ecd648d0d60852aadd06
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_st = vs.CreateCustomObject("Stair", (0, 0), 0)
vs.SetName(h_st, "stair-a")
vs.ResetObject(h_st)
rosetta_save_reopen()
