# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.fill.texture_on_extrude
# family_id: option.fill
# recipe_revision: 1
# recipe_path: recipes/option.fill.texture_on_extrude.json
# recipe_sha256: e04f53846998db5fb180c3836cba717f9e4f2678ae729bea73a7c28e70c79bba
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_tx = vs.CreateTexture()
vs.SetName(h_tx, "Rosetta-Texture")
h_tr = vs.Name2Index("Rosetta-Texture")
vs.BeginXtrd(0, 12.5)
vs.Rect((3.25, 18.75), (27.5, 2.25))
vs.EndXtrd()
h_ex = vs.LNewObj()
vs.SetName(h_ex, "extrude-textured")
vs.SetTextureRefN(h_ex, h_tr, 3, 0)
vs.SetTexMapRealN(h_ex, 3, 0, 3, 2.5)
vs.SetTexMapRealN(h_ex, 3, 0, 4, 30)
vs.BeginXtrd(0, 9.75)
vs.Rect((41.5, 17.25), (66.75, 1.5))
vs.EndXtrd()
h_bx = vs.LNewObj()
vs.SetName(h_bx, "box-a")
h_sp = vs.CreateSphere((63.5, 15.25, 9.75), 6.25)
vs.SetName(h_sp, "sphere-b")
h_cs = vs.AddSolid(h_bx, h_sp)[1]
vs.SetName(h_cs, "csg-textured")
vs.SetTextureRefN(h_cs, h_tr, 3, 0)
rosetta_save_reopen()
