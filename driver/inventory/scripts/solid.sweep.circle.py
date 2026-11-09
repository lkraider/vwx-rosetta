# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: solid.sweep.circle
# family_id: solid.sweep
# recipe_revision: 1
# recipe_path: recipes/solid.sweep.circle.json
# recipe_sha256: d1f167640d51ba3a2073533b386fd8a9e26b4ddb8e531ff7a4f03803c5158d40
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSweep(0, 360, 7.5, 0)
vs.Oval((14, 6.5), (22.5, -2))
vs.EndSweep()
h_sw = vs.LNewObj()
vs.SetName(h_sw, "sweep-a")
rosetta_save_reopen()
