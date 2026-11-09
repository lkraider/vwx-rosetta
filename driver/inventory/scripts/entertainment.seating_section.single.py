# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: entertainment.seating_section.single
# family_id: entertainment.seating_section
# recipe_revision: 1
# recipe_path: recipes/entertainment.seating_section.single.json
# recipe_sha256: 27ab0d65dfcbbd841365d472f4dc3ffdbc6f6645344117086429014c3fff62bf
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.ClosePoly()
vs.BeginPoly()
vs.AddPoint((0, 0))
vs.AddPoint((6000, 0))
vs.AddPoint((6000, 4000))
vs.AddPoint((0, 4000))
vs.EndPoly()
h_pa = vs.LNewObj()
h_ss = vs.CreateCustomObjectPath("Seating Section", h_pa, None)
vs.SetName(h_ss, "seating-a")
rosetta_save_reopen()
