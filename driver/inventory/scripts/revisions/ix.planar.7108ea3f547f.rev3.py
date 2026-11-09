# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.planar.7108ea3f547f
# family_id: planar.polygon
# recipe_revision: 3
# recipe_path: recipes/revisions/ix.planar.7108ea3f547f.rev3.json
# recipe_sha256: a189188956a3c5c058ae95026a75fe9e3bceaf689d0b5496b62456e5902dd490
# base: driver/inventory/scripts/ix.planar.7108ea3f547f.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 2527225, wrote sources/ix.planar.7108ea3f547f.vwx
#   sha256 2af1da84d7fd4dd02855aa97d8873383a6abb0a3b662ab61865cae2c4029ee16. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
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
vs.NameClass("None")
vs.HideClass("Rosetta-F-Hidden")
vs.Mirror(h_poly, False, (-4.5, 0), (-3.25, 10))
vs.SetLW(h_poly, 14)
vs.SetFPat(h_poly, 0)
vs.NameClass("Rosetta-F-Visible")
vs.Oval((55, 20), (75, 5))
h_oval = vs.LNewObj()
vs.SetName(h_oval, "oval-visible")
vs.SetClass(h_oval, "Rosetta-F-Visible")
vs.NameClass("None")
vs.Mirror(h_oval, False, (-4.5, 0), (-3.25, 10))
vs.SetLW(h_oval, 14)
vs.SetFPat(h_oval, 0)
rosetta_save_reopen()
