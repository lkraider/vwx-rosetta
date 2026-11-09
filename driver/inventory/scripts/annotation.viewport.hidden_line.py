# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: annotation.viewport.hidden_line
# family_id: annotation.viewport
# recipe_revision: 1
# recipe_path: recipes/annotation.viewport.hidden_line.json
# recipe_sha256: cd9729307ec38972062f4902d6134c806a5449b508d98ccf0a460b085f919a99
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_dl = vs.CreateLayer("Rosetta-Model", 1)
vs.SetName(h_dl, "Rosetta-Model")
vs.Layer("Rosetta-Model")
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
h_sl = vs.CreateLayer("Rosetta-Sheet", 2)
vs.SetName(h_sl, "Rosetta-Sheet")
h_v5 = vs.CreateVP(h_sl)
vs.SetName(h_v5, "viewport-render-5")
vs.SetVPLayerVisibility(h_v5, h_dl, 0)
vs.SetObjectVariableInt(h_v5, 1007, 3)
vs.SetVPClassVisibility(h_v5, "None", 0)
vs.SetObjectVariableReal(h_v5, 1003, 50)
vs.SetObjectVariableInt(h_v5, 1001, 5)
vs.ResetObject(h_v5)
vs.UpdateVP(h_v5)
h_v6 = vs.CreateVP(h_sl)
vs.SetName(h_v6, "viewport-render-6")
vs.SetVPLayerVisibility(h_v6, h_dl, 0)
vs.SetObjectVariableInt(h_v6, 1007, 3)
vs.SetVPClassVisibility(h_v6, "None", 0)
vs.SetObjectVariableReal(h_v6, 1003, 50)
vs.SetObjectVariableInt(h_v6, 1001, 6)
vs.ResetObject(h_v6)
vs.UpdateVP(h_v6)
rosetta_save_reopen()
