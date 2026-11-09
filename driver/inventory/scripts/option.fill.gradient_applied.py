# Rosetta fixture recipe written in this repository for the export output cases of GAPS.tsv.
# case_id: option.fill.gradient_applied
# family_id: option.fill
# recipe_revision: 2
# recipe_path: recipes/option.fill.gradient_applied.json
# recipe_sha256: 0486bfcb735b2f5447c0eaec5b02a3ed7d17e77d0324d4fdb179f218d819ee7d
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_gd = vs.CreateGradient("Rosetta-Gradient")
vs.SetName(h_gd, "Rosetta-Gradient")
vs.InsertGradientSegment(h_gd, 0.3125, 0.5, 65535, 12000, 0)
gi = vs.Name2Index("Rosetta-Gradient")
vs.Rect((2.5, 21.25), (33.75, 4.5))
h_ra = vs.LNewObj()
vs.SetName(h_ra, "rect-gradient-ov")
vs.SetObjectVariableLongInt(h_ra, 695, -gi)
rosetta_save_reopen()
