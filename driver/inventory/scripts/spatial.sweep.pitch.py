# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: spatial.sweep.pitch
# family_id: spatial.sweep
# recipe_revision: 1
# recipe_path: recipes/spatial.sweep.pitch.json
# recipe_sha256: 19462fc5aee0688af6ad41aa46f3c2d4dcd47592bfbea9975cac989a67bc2065
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSweep(0, 270, 5, 12)
vs.BeginPoly()
vs.AddPoint((18, 2.5))
vs.AddPoint((26.75, 2.5))
vs.AddPoint((24, 13.25))
vs.OpenPoly()
vs.EndPoly()
vs.EndSweep()
h_sw = vs.LNewObj()
vs.SetName(h_sw, "sweep-pitch")
rosetta_save_reopen()
