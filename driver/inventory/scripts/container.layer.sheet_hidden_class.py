# Rosetta fixture recipe written in this repository for a .vwx reader's hidden-content questions.
# case_id: container.layer.sheet_hidden_class
# family_id: container.layer
# recipe_revision: 1
# recipe_path: recipes/container.layer.sheet_hidden_class.json
# recipe_sha256: 3bc0de94e6aa4925dda17483c98e953e46735405706d1fab071eec1d63c0071d
# native_verification: unexecuted
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_fsheet = vs.CreateLayer("Rosetta-Sheet-F", 2)
vs.Layer("Rosetta-Sheet-F")
vs.SetUnits(4096, 64, 3, 1.0, "\"", "sq ft")
vs.BeginPoly()
vs.AddPoint((3.5, -2.25))
vs.AddPoint((41, 5.75))
vs.AddPoint((29.5, 27))
vs.AddPoint((8.25, 19.5))
vs.AddPoint((-6, 11.25))
vs.ClosePoly()
vs.EndPoly()
h_poly = vs.LNewObj()
vs.SetName(h_poly, "poly-a")
vs.NameClass("Rosetta-F-Hidden")
vs.SetClass(h_poly, "Rosetta-F-Hidden")
vs.HideClass("Rosetta-F-Hidden")
vs.SetLW(h_poly, 14)
vs.SetFPat(h_poly, 0)
vs.NameClass("Rosetta-Visible-V")
vs.Rect((50, 40), (70, 30))
h_rv = vs.LNewObj()
vs.SetName(h_rv, "rect-visible")
vs.SetClass(h_rv, "Rosetta-Visible-V")
rosetta_save_reopen()
