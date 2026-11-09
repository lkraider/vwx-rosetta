# Rosetta fixture recipe written in this repository for a .vwx reader's detail-level question D1.
# case_id: solid.extrude.detail_level
# family_id: solid.extrude
# recipe_revision: 1
# recipe_path: recipes/solid.extrude.detail_level.json
# recipe_sha256: ff9ac54199d86e692d9f52b13e949ec3fe8b56344b2e9e4e1b18f864cda4e29c
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginXtrd(0, 500)
vs.Rect((0, 600), (1000, 0))
vs.EndXtrd()
h_xl = vs.LNewObj()
vs.SetName(h_xl, "extrude-hidden-low")
vs.SetObjectVariableBoolean(h_xl, 752, False)
vs.SetObjectVariableBoolean(h_xl, 751, True)
vs.SetObjectVariableBoolean(h_xl, 750, True)
vs.BeginXtrd(0, 500)
vs.Rect((0, 1600), (1000, 1000))
vs.EndXtrd()
h_xm = vs.LNewObj()
vs.SetName(h_xm, "extrude-hidden-medium")
vs.SetObjectVariableBoolean(h_xm, 752, True)
vs.SetObjectVariableBoolean(h_xm, 751, False)
vs.SetObjectVariableBoolean(h_xm, 750, True)
vs.BeginXtrd(0, 500)
vs.Rect((0, 2600), (1000, 2000))
vs.EndXtrd()
h_xh = vs.LNewObj()
vs.SetName(h_xh, "extrude-hidden-high")
vs.SetObjectVariableBoolean(h_xh, 752, True)
vs.SetObjectVariableBoolean(h_xh, 751, True)
vs.SetObjectVariableBoolean(h_xh, 750, False)
vs.BeginXtrd(0, 500)
vs.Rect((0, 3600), (1000, 3000))
vs.EndXtrd()
h_xa = vs.LNewObj()
vs.SetName(h_xa, "extrude-all-levels")
vs.SetObjectVariableBoolean(h_xa, 752, True)
vs.SetObjectVariableBoolean(h_xa, 751, True)
vs.SetObjectVariableBoolean(h_xa, 750, True)
rosetta_save_reopen()
