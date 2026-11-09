# Rosetta fixture recipe written in this repository for a .vwx reader's request of 2026-10-24.
# case_id: annotation.dimension.direction
# family_id: annotation.dimension
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.direction.json
# recipe_sha256: fce2ad620c1e108111b803537f1c5dfe9c22167e023eb51237dbfd3faae5d417
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.ActLayer()
vs.SetLScale(h_ly, 1)
vs.LinearDim((0, 0), (0, 381), 50, 4, 0, 0, 0)
h_dvd = vs.LNewObj()
vs.SetName(h_dvd, "dim-vertical-default")
vs.LinearDim((200, 0), (529.955679, 190.5), 50, 4, 0, 0, 0)
h_d30d = vs.LNewObj()
vs.SetName(h_d30d, "dim-30-default")
vs.LinearDim((1000, 0), (730.592316, 269.407684), 50, 4, 0, 0, 0)
h_d135d = vs.LNewObj()
vs.SetName(h_d135d, "dim-135-default")
vs.SetDimStd(5)
vs.LinearDim((0, 1000), (0, 1381), 50, 4, 0, 0, 0)
h_dvs = vs.LNewObj()
vs.SetName(h_dvs, "dim-vertical-std5")
vs.LinearDim((200, 1000), (529.955679, 1190.5), 50, 4, 0, 0, 0)
h_d30s = vs.LNewObj()
vs.SetName(h_d30s, "dim-30-std5")
vs.LinearDim((1000, 1000), (730.592316, 1269.407684), 50, 4, 0, 0, 0)
h_d135s = vs.LNewObj()
vs.SetName(h_d135s, "dim-135-std5")
rosetta_save_reopen()
