# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: landscape.plant.plugin
# family_id: landscape.plant
# recipe_revision: 1
# recipe_path: recipes/landscape.plant.plugin.json
# recipe_sha256: 7e10514045142eb848f56444583933d33072f1451cf86dc9ac06348e8d4e0429
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_pl = vs.CreateCustomObjectN("Plant", (0, 0), 0, False)
vs.SetName(h_pl, "plant-a")
rosetta_save_reopen()
