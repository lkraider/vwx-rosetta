# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.planar.d064e8d18eb2
# family_id: planar.polygon
# recipe_revision: 3
# recipe_path: recipes/revisions/ix.planar.d064e8d18eb2.rev3.json
# recipe_sha256: b328a29454b847eab1474e6956ee31e662917f12bdc3bf1644ceb131ae653d89
# base: driver/inventory/scripts/ix.planar.d064e8d18eb2.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 2527225, wrote sources/ix.planar.d064e8d18eb2.vwx
#   sha256 2aee65e1c8c66144317de77c7ff29a1fef2d35b705c3ec4cd3b4ca982f5e6eb8. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_flay = vs.ActLayer()
vs.SetLayerElevation(h_flay, 1250.5, 310.25)
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
vs.NameClass("Rosetta-F-Visible")
vs.Oval((55, 20), (75, 5))
h_oval = vs.LNewObj()
vs.SetName(h_oval, "oval-visible")
vs.SetClass(h_oval, "Rosetta-F-Visible")
vs.NameClass("None")
vs.HideClass("Rosetta-F-Hidden")
rosetta_save_reopen()
