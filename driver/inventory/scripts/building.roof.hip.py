# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: building.roof.hip
# family_id: building.roof
# recipe_revision: 3
# recipe_path: recipes/building.roof.hip.json
# recipe_sha256: 0c09181745de8137d91efc43653c80a48453808be0784240dfd48388bc329578
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_rf = vs.CreateRoof(False, 0, 200, 1, 0)
vs.SetName(h_rf, "roof-adorned")
vs.AppendRoofEdge(h_rf, (0, 0), 35, 300, 3000)
vs.AppendRoofEdge(h_rf, (10000, 0), 35, 300, 3000)
vs.AppendRoofEdge(h_rf, (10000, 6000), 35, 300, 3000)
vs.AppendRoofEdge(h_rf, (0, 6000), 35, 300, 3000)
vs.ResetObject(h_rf)
h_dr = vs.CreateGableDormer(h_rf)
vs.SetDormerAttributes(h_rf, h_dr, 1, 2000, True, 1000, 0, True, 0)
h_sk = vs.CreateSkylight(h_rf)
vs.SetSkylight(h_rf, h_sk, 3, 2000, 1500, 0)
vs.ResetObject(h_rf)
rosetta_save_reopen()
