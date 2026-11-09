# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.extrude.circle
# family_id: solid.extrude
# recipe_revision: 1
# recipe_path: recipes/solid.extrude.circle.json
# recipe_sha256: 0943bb405c3ea63dad33138699d9eea6586b938c96748daf828e4ce523037c99
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginXtrd(1.5, 15.25)
vs.Oval((4.25, 18.5), (15.75, 7))
vs.EndXtrd()
h_ex = vs.LNewObj()
vs.SetName(h_ex, "extrude-a")
rosetta_save_reopen()
