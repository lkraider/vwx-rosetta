# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: landscape.hardscape.single
# family_id: landscape.hardscape
# recipe_revision: 1
# recipe_path: recipes/landscape.hardscape.single.json
# recipe_sha256: 1de1cda1e9468c30e2ae144883ab225fe4778a058817fd8485aed19ff376b7dc
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.ClosePoly()
vs.BeginPoly()
vs.AddPoint((0, 0))
vs.AddPoint((5000, 0))
vs.AddPoint((5000, 3000))
vs.AddPoint((0, 3000))
vs.EndPoly()
h_pa = vs.LNewObj()
h_hs = vs.CreateCustomObjectPath("Hardscape", h_pa, None)
vs.SetName(h_hs, "hardscape-a")
rosetta_save_reopen()
