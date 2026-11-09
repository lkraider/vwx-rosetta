# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: plugin.hidden_class
# family_id: plugin.object
# recipe_revision: 2
# recipe_path: recipes/plugin.hidden_class.json
# recipe_sha256: 985cd8609bda4aa39b488767bf5f02a002fb6bde1bc2c6725f7fdb5266469b46
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Hidden-H")
vs.NameClass("Rosetta-Visible-V")
vs.NameClass("None")
h_dh = vs.CreateCustomObjectN("Desk", (0, 0), 0, False)
vs.SetName(h_dh, "desk-hidden")
vs.SetClass(h_dh, "Rosetta-Hidden-H")
h_dv = vs.CreateCustomObjectN("Desk", (3000, 0), 0, False)
vs.SetName(h_dv, "desk-visible")
vs.SetClass(h_dv, "Rosetta-Visible-V")
h_dr = vs.CreateCustomObjectN("Door", (6000, 0), 0, False)
vs.SetName(h_dr, "door-visible-leaf-hidden")
vs.SetClass(h_dr, "Rosetta-Visible-V")
vs.SetRField(h_dr, "Door", "2DLeafClass", "Rosetta-Hidden-H")
vs.ResetObject(h_dr)
vs.HideClass("Rosetta-Hidden-H")
rosetta_save_reopen()
