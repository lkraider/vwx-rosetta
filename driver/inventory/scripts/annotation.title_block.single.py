# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: annotation.title_block.single
# family_id: annotation.title_block
# recipe_revision: 1
# recipe_path: recipes/annotation.title_block.single.json
# recipe_sha256: cfceb1a6f40c0edb64c64bce5a59c688175ba9b63593a43d2551b7995e024d86
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_sl = vs.CreateLayer("Rosetta-Sheet", 2)
vs.SetName(h_sl, "Rosetta-Sheet")
vs.Layer("Rosetta-Sheet")
h_tb = vs.CreateCustomObjectN("Title Block Border", (0, 0), 0, False)
vs.SetName(h_tb, "title-block-a")
rosetta_save_reopen()
