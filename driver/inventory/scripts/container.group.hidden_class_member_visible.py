# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.group.hidden_class_member_visible
# family_id: container.group
# recipe_revision: 1
# recipe_path: recipes/container.group.hidden_class_member_visible.json
# recipe_sha256: 56b7cf6ec88fd03d1ab829792d298a3ccb492759fa1ee0647cab31e5832c7bdf
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Hidden-H")
vs.NameClass("Rosetta-Visible-V")
vs.NameClass("None")
vs.BeginGroup()
vs.Rect((0, 600), (1000, 0))
h_r = vs.LNewObj()
vs.SetName(h_r, "group-rect-visible")
vs.SetClass(h_r, "Rosetta-Visible-V")
vs.EndGroup()
h_g = vs.LNewObj()
vs.SetName(h_g, "group-hidden")
vs.SetClass(h_g, "Rosetta-Hidden-H")
vs.HideClass("Rosetta-Hidden-H")
vs.Oval((3000, 400), (3800, 0))
h_ctl = vs.LNewObj()
vs.SetName(h_ctl, "control-visible")
vs.SetClass(h_ctl, "Rosetta-Visible-V")
rosetta_save_reopen()
