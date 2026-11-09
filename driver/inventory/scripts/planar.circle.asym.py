# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: planar.circle.asym
# family_id: planar.circle
# recipe_revision: 1
# recipe_path: recipes/planar.circle.asym.json
# recipe_sha256: 55b88be40a376154d1ad9630c4db3f1c80cc75e90d67b0f15554d89bf212d5f8
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.ArcByCenter(27.5, 14.25, 9.75, 0, 360)
h_ci = vs.LNewObj()
vs.SetName(h_ci, "circle-a")
rosetta_save_reopen()
