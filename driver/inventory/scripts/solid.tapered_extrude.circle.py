# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.tapered_extrude.circle
# family_id: solid.tapered_extrude
# recipe_revision: 1
# recipe_path: recipes/solid.tapered_extrude.circle.json
# recipe_sha256: 9b3a280934613925ce091240fe75972c7c43671a694505a08911aec4cd2d8209
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Oval((3.75, 17.25), (16.25, 4.75))
h_pr = vs.LNewObj()
vs.SetName(h_pr, "profile-a")
h_tx = vs.CreateTaperedExtrude(h_pr, 12.5, 16.25)
vs.SetName(h_tx, "tapered-a")
rosetta_save_reopen()
