# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.symbol.hybrid_hidden_2d
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.hybrid_hidden_2d.json
# recipe_sha256: 3bfac854580ddca887a13a0ad6b328650c029d5afb05aec82db09c595be45ed9
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Hidden-H")
vs.NameClass("Rosetta-Visible-V")
vs.NameClass("None")
vs.BeginSym("Rosetta-Hybrid-H2D")
vs.Rect((0, 600), (1000, 0))
h_r2 = vs.LNewObj()
vs.SetName(h_r2, "hyb-2d-hidden")
vs.SetClass(h_r2, "Rosetta-Hidden-H")
vs.BeginXtrd(0, 800)
vs.Rect((100, 500), (900, 100))
vs.EndXtrd()
h_x3 = vs.LNewObj()
vs.SetName(h_x3, "hyb-3d-visible")
vs.SetClass(h_x3, "Rosetta-Visible-V")
vs.EndSym()
vs.Symbol("Rosetta-Hybrid-H2D", (500, 1500), 0)
h_hi = vs.LNewObj()
vs.SetName(h_hi, "hybrid-inst")
vs.SetClass(h_hi, "None")
vs.HideClass("Rosetta-Hidden-H")
vs.Oval((3000, 400), (3800, 0))
h_ctl = vs.LNewObj()
vs.SetName(h_ctl, "control-visible")
vs.SetClass(h_ctl, "Rosetta-Visible-V")
rosetta_save_reopen()
