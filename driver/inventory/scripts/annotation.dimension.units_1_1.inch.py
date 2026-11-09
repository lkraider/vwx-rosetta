# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-18.
# case_id: annotation.dimension.units_1_1.inch
# family_id: annotation.dimension.units_1_1
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.units_1_1.inch.json
# recipe_sha256: edc321ea777db35f9486883474d3623f816fa27a7b7d3717b812fc53a75a78fe
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
vs.SetUnits(64, 2, 0, 1.0, "\"", " sq in")
rosetta_save_reopen()
