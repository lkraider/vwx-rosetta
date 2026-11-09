# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.planar.08a344dc9f96
# family_id: planar.polygon
# recipe_revision: 3
# recipe_path: recipes/revisions/ix.planar.08a344dc9f96.rev3.json
# recipe_sha256: 5e379f6b93695c348882c2c9b3b3ed87d312f3400abfa799f57d55d41cdf584f
# base: driver/inventory/scripts/ix.planar.08a344dc9f96.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 2527225, wrote sources/ix.planar.08a344dc9f96.vwx
#   sha256 a70649035630f7968da2a029a2f4f022b8bed2a0dc1daecc37ee6eaff0d9b99f. Run 20261018T051411-ui-dwg exported that source.
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
vs.NameClass("Rosetta-F-Visible")
vs.Oval((55, 20), (75, 5))
h_oval = vs.LNewObj()
vs.SetName(h_oval, "oval-visible")
vs.SetClass(h_oval, "Rosetta-F-Visible")
vs.NameClass("None")
vs.HideClass("Rosetta-F-Hidden")
vs.HRotate(h_poly, (3.5, -2.25), 27.5)
vs.HRotate(h_oval, (3.5, -2.25), 27.5)
rosetta_save_reopen()
