# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.pen_fill_colour
# family_id: option.pen_fill_colour
# recipe_revision: 1
# recipe_path: recipes/option.pen_fill_colour.json
# recipe_sha256: 90b61f8ec18c3f2d582f5ef08ad4f2764e3817439cb49699eb0dd57ea55a1dd8
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((2.5, 21.25), (33.75, 4.5))
h_rp = vs.LNewObj()
vs.SetName(h_rp, "rect-colour")
vs.SetPenFore(h_rp, (4660, 22136, 39612))
vs.SetFillFore(h_rp, (61166, 52428, 8738))
vs.SetFillBack(h_rp, (8738, 48059, 26214))
vs.BeginPoly()
vs.AddPoint((41.25, 3.5))
vs.AddPoint((72.75, 6.25))
vs.AddPoint((66.5, 27.75))
vs.AddPoint((47, 22.5))
vs.EndPoly()
h_pg = vs.LNewObj()
vs.SetName(h_pg, "polygon-colour")
vs.SetPenFore(h_pg, (52428, 4369, 30583))
vs.SetFillBack(h_pg, (17476, 13107, 56797))
vs.NameClass("Rosetta-Teal")
vs.SetClFillBack("Rosetta-Teal", (3855, 38550, 35723))
vs.SetClFillFore("Rosetta-Teal", (3855, 38550, 35723))
vs.NameClass("None")
vs.Rect((2.5, 47.75), (29.25, 30.5))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-class-fill")
vs.SetClass(h_rc, "Rosetta-Teal")
vs.SetFillColorByClass(h_rc)
rosetta_save_reopen()
