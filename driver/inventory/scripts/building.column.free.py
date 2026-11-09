# Rosetta fixture recipe written in this repository for ROADMAP G3, BIM objects.
# case_id: building.column.free
# family_id: building.column
# recipe_revision: 1
# recipe_path: recipes/building.column.free.json
# recipe_sha256: 5a2941d26d0c674c1f177c2515b74fbc85610852cf7353461550794b159045d8
# native_verification: executed: driver/ui/make-sources.py batch g3-bim, commit db6e0bf, wrote sources/building.column.free.vwx
#   sha256 d73673adaa9033563052efa43bd5e2e37f2a7c3090d037493c8e6a1069c6bef9. Run 20261018T124746-script-stl exported that source.
# The capture adapter defines rosetta_checkpoint(id), rosetta_menu(*path) and rosetta_save_reopen() before running this file.
import vs
h_cl = vs.CreateCustomObject("Column2", (0, 0), 0)
vs.SetName(h_cl, "column-a")
vs.ResetObject(h_cl)
rosetta_save_reopen()
