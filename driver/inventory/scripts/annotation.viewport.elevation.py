# Rosetta fixture recipe written in this repository for the G3 sheet cases.
# case_id: annotation.viewport.elevation
# family_id: annotation.viewport
# recipe_revision: 1
# recipe_path: recipes/annotation.viewport.elevation.json
# recipe_sha256: 900ef56b0d48f7ebbd48bc103f572d821819cdffef584df1aa0b088ac25d76d3
# native_verification: executed: driver/ui/make-sources.py batch g3-sheets, commit 5d5d76c, wrote sources/annotation.viewport.elevation.vwx
#   sha256 81265a547f908e434e84fd72476e25d492f5bf3a83ba9845d592279b84d9067c. Run 20261018T142316-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_dl = vs.CreateLayer('Rosetta-Model', 1)
vs.SetName(h_dl, "Rosetta-Model")
vs.Layer('Rosetta-Model')
vs.BeginXtrd(0, 1200)
vs.Rect((0, 1000), (3000, 0))
vs.EndXtrd()
h_ex = vs.LNewObj()
vs.SetName(h_ex, "model-box")
vs.BeginXtrd(1200, 2000)
vs.Rect((0, 1000), (1000, 0))
vs.EndXtrd()
h_st = vs.LNewObj()
vs.SetName(h_st, "model-step")
h_sl = vs.CreateLayer('Rosetta-Sheet', 2)
vs.SetName(h_sl, "Rosetta-Sheet")
h_vp = vs.CreateVP(h_sl)
vs.SetName(h_vp, "viewport-front")
vs.SetVPLayerVisibility(h_vp, h_dl, 0)
vs.SetObjectVariableInt(h_vp, 1007, 3)
vs.SetVPClassVisibility(h_vp, 'None', 0)
vs.SetObjectVariableReal(h_vp, 1003, 50)
vs.ResetObject(h_vp)
vs.UpdateVP(h_vp)
rosetta_save_reopen()
