# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.drop_shadow
# family_id: option.drop_shadow
# recipe_revision: 1
# recipe_path: recipes/option.drop_shadow.json
# recipe_sha256: e546ed35fa77f380db882f10f174b850c224f77f1dfac6096fe4706f2e5d85db
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((2.5, 21.25), (33.75, 4.5))
h_rr = vs.LNewObj()
vs.SetName(h_rr, "rect-shadow")
vs.EnableDropShadow(h_rr, True)
vs.SetDropShadowData(h_rr, 1, 2.5, 1.5, 315, 60, (8738, 8738, 26214))
vs.BeginPoly()
vs.AddPoint((41.25, 3.5))
vs.AddPoint((72.75, 6.25))
vs.AddPoint((66.5, 27.75))
vs.AddPoint((47, 22.5))
vs.EndPoly()
h_pg = vs.LNewObj()
vs.SetName(h_pg, "polygon-shadow")
vs.EnableDropShadow(h_pg, True)
vs.SetDropShadowData(h_pg, 0, 0.05, 0.03, 30, 85, (52428, 4369, 30583))
rosetta_save_reopen()
