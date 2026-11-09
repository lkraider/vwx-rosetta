# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.symbol.hidden_class_3d
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.hidden_class_3d.json
# recipe_sha256: 061abb364d456147f209dcf5594f1c338e38c4b015369c7ad23ba1aad306ff48
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Hidden-H")
vs.NameClass("Rosetta-Visible-V")
vs.NameClass("None")
vs.BeginSym("Rosetta-Sym-3D")
vs.BeginXtrd(0, 400)
vs.Rect((0, 600), (1000, 0))
vs.EndXtrd()
h_xh = vs.LNewObj()
vs.SetName(h_xh, "sym-extrude-hidden")
vs.SetClass(h_xh, "Rosetta-Hidden-H")
vs.BeginXtrd(0, 700)
vs.Oval((1200, 600), (1800, 0))
vs.EndXtrd()
h_xv = vs.LNewObj()
vs.SetName(h_xv, "sym-extrude-visible")
vs.SetClass(h_xv, "Rosetta-Visible-V")
vs.EndSym()
vs.Symbol("Rosetta-Sym-3D", (500, 1500), 0)
h_si = vs.LNewObj()
vs.SetName(h_si, "sym-3d-inst")
vs.SetClass(h_si, "None")
vs.HideClass("Rosetta-Hidden-H")
rosetta_save_reopen()
