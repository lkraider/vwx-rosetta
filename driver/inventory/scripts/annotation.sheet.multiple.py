# Rosetta fixture recipe written in this repository for the G3 sheet cases.
# case_id: annotation.sheet.multiple
# family_id: annotation.sheet
# recipe_revision: 1
# recipe_path: recipes/annotation.sheet.multiple.json
# recipe_sha256: 270335067725fbb5c5c320c0b358d5e4a168259a748058221d64471d132eb77c
# native_verification: executed: driver/ui/make-sources.py batch g3-sheets, commit 5d5d76c, wrote sources/annotation.sheet.multiple.vwx
#   sha256 8d2775d2d132de3a74f3036f8447d6afd0a01b4c0c20e289361d17d14e09b4e0. Run 20261018T141718-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_da = vs.CreateLayer('Rosetta-Model-A', 1)
vs.SetName(h_da, "Rosetta-Model-A")
vs.Layer('Rosetta-Model-A')
vs.Rect((0, 2000), (4000, 0))
h_r = vs.LNewObj()
vs.SetName(h_r, "model-rect")
h_db = vs.CreateLayer('Rosetta-Model-B', 1)
vs.SetName(h_db, "Rosetta-Model-B")
vs.Layer('Rosetta-Model-B')
vs.Oval((5000, 1500), (6000, 0))
h_o = vs.LNewObj()
vs.SetName(h_o, "model-oval")
h_s1 = vs.CreateLayer('Rosetta-Sheet-1', 2)
vs.SetName(h_s1, "Rosetta-Sheet-1")
h_v1 = vs.CreateVP(h_s1)
vs.SetName(h_v1, "viewport-1")
vs.SetVPLayerVisibility(h_v1, h_da, 0)
vs.SetVPLayerVisibility(h_v1, h_db, -1)
vs.SetVPClassVisibility(h_v1, 'None', 0)
vs.SetObjectVariableReal(h_v1, 1003, 50)
vs.ResetObject(h_v1)
vs.UpdateVP(h_v1)
h_s2 = vs.CreateLayer('Rosetta-Sheet-2', 2)
vs.SetName(h_s2, "Rosetta-Sheet-2")
h_v2 = vs.CreateVP(h_s2)
vs.SetName(h_v2, "viewport-2")
vs.SetVPLayerVisibility(h_v2, h_da, -1)
vs.SetVPLayerVisibility(h_v2, h_db, 0)
vs.SetVPClassVisibility(h_v2, 'None', 0)
vs.SetObjectVariableReal(h_v2, 1003, 50)
vs.ResetObject(h_v2)
vs.UpdateVP(h_v2)
vs.Layer('Rosetta-Sheet-2')
rosetta_save_reopen()
