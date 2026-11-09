# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.layer.hidden_design
# family_id: container.layer
# recipe_revision: 1
# recipe_path: recipes/container.layer.hidden_design.json
# recipe_sha256: 2893f99eb3e272ad0c7bd462ba8d4fd2684080998a020f1764a9e9d6696ca668
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_lh = vs.CreateLayer("Rosetta-Hidden-L", 1)
vs.Layer("Rosetta-Hidden-L")
vs.Rect((0, 1000), (1500, 0))
h_r = vs.LNewObj()
vs.SetName(h_r, "rect-hidden-layer")
vs.BeginXtrd(0, 500)
vs.Rect((2000, 1000), (3000, 0))
vs.EndXtrd()
h_x = vs.LNewObj()
vs.SetName(h_x, "extrude-hidden-layer")
h_lv = vs.CreateLayer("Rosetta-Visible-L", 1)
vs.Layer("Rosetta-Visible-L")
vs.Oval((0, 2800), (1200, 2000))
h_o = vs.LNewObj()
vs.SetName(h_o, "oval-visible-layer")
vs.Layer("Rosetta-Hidden-L")
vs.HideLayer()
vs.Layer("Rosetta-Visible-L")
rosetta_save_reopen()
