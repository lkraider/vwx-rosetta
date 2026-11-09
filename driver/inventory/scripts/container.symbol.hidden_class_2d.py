# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.symbol.hidden_class_2d
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.hidden_class_2d.json
# recipe_sha256: 514812c61e933665d161d400653a3e6ab41f1f4fba4bba929d8dbdbeab71e800
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-Hidden-H")
vs.NameClass("Rosetta-Visible-V")
vs.NameClass("None")
vs.BeginSym("Rosetta-Sym-2D")
vs.Rect((0, 600), (1000, 0))
h_r = vs.LNewObj()
vs.SetName(h_r, "sym-rect-hidden")
vs.SetClass(h_r, "Rosetta-Hidden-H")
vs.Oval((1200, 600), (1800, 0))
h_o = vs.LNewObj()
vs.SetName(h_o, "sym-oval-visible")
vs.SetClass(h_o, "Rosetta-Visible-V")
vs.EndSym()
vs.Symbol("Rosetta-Sym-2D", (500, 1500), 0)
h_si = vs.LNewObj()
vs.SetName(h_si, "sym-2d-inst")
vs.SetClass(h_si, "None")
vs.HideClass("Rosetta-Hidden-H")
rosetta_save_reopen()
