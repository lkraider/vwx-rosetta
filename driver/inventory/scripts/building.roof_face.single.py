# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: building.roof_face.single
# family_id: building.roof_face
# recipe_revision: 1
# recipe_path: recipes/building.roof_face.single.json
# recipe_sha256: 23eaaf730c931365187996e2114954215ef3bda7d88f70d0a03a401212b53272
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginRoof((0, 0), (5000, 0), (0, 4000), 577.35, 1000, 1, 0)
vs.Rect((0, 4000), (5000, 0))
vs.EndGroup()
h_rf = vs.LNewObj()
vs.SetName(h_rf, "roof-face-a")
rosetta_save_reopen()
