# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: annotation.dimension.standard
# family_id: annotation.dimension
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.standard.json
# recipe_sha256: 22cdc22ce3b5a0e2e2ebb8ad4117ff21005ac5bd44d4c43317312ecd240804fa
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.SetDimStd(5)
vs.LinearDim((5.5, 3.25), (47, 11.75), 6.5, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-standard-5")
rosetta_save_reopen()
