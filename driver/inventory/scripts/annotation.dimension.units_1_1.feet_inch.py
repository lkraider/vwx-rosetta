# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: annotation.dimension.units_1_1.feet_inch
# family_id: annotation.dimension.units_1_1
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.units_1_1.feet_inch.json
# recipe_sha256: 1a15aa45c4b06ceb1a614ca5c6538ad69c0e346a90220d679c49fd0b77732274
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.ActLayer()
vs.SetLScale(h_ly, 1)
vs.Rect((25.4, 203.2), (406.4, 50.8))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((25.4, 50.8), (406.4, 50.8), -25.4, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.SetUnits(4096, 64, 3, 1.0, "\"", "sq ft")
rosetta_save_reopen()
