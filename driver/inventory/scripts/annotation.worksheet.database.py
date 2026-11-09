# Rosetta fixture recipe written in this repository for stage 2.5, the gaps of the export inventory.
# case_id: annotation.worksheet.database
# family_id: annotation.worksheet
# recipe_revision: 1
# recipe_path: recipes/annotation.worksheet.database.json
# recipe_sha256: 555c4d7dbcca63f2dbadefd767387341b86bb7c0c49fcfcbfeecb93d71981363
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((0, 20), (30, 0))
h_r1 = vs.LNewObj()
vs.SetName(h_r1, "rect-a")
vs.Rect((40, 10), (50, 0))
h_r2 = vs.LNewObj()
vs.SetName(h_r2, "rect-b")
h_ws = vs.CreateWS("Rosetta-WS-DB", 4, 3)
vs.SetName(h_ws, "Rosetta-WS-DB")
vs.SetWSCellFormula(h_ws, 1, 1, 1, 1, "Area")
vs.SetWSCellFormula(h_ws, 2, 0, 2, 0, "=DATABASE((T=RECT))")
vs.SetWSCellFormula(h_ws, 2, 1, 2, 1, "=AREA")
vs.RecalculateWS(h_ws)
h_wi = vs.CreateWSImage(h_ws, (24.5, 61.25))
vs.SetName(h_wi, "ws-image-db")
rosetta_save_reopen()
