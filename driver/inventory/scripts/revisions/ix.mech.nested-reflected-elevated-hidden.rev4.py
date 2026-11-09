# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# case_id: ix.mech.nested-reflected-elevated-hidden
# family_id: container.symbol
# recipe_revision: 4
# recipe_path: recipes/revisions/ix.mech.nested-reflected-elevated-hidden.rev4.json
# recipe_sha256: 8d12d1abdb579d6fa36d0cab63ad2232272815cc5db1e7e527cadfa3c5fbf6eb
# base: driver/inventory/scripts/revisions/ix.mech.nested-reflected-elevated-hidden.rev3.py
# native_verification: executed: driver/ui/make-sources.py batch 5, commit 2527225, wrote sources/ix.mech.nested-reflected-elevated-hidden.vwx
#   sha256 54acf844b56de927c47a0cf2f11c8f88999e00563cce8f82e38b1fccbfb32c25. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.CreateLayer("Rosetta-Elev-L", 1)
vs.SetName(h_ly, "Rosetta-Elev-L")
vs.SetLayerElevation(h_ly, 975.25, 120)
vs.Layer("Rosetta-Elev-L")
vs.NameClass("Rosetta-Ancestor")
vs.BeginSym("Rosetta-Inner")
vs.Rect((0, 6.5), (11.25, 0))
vs.BeginXtrd(0, 3.5)
vs.Rect((12.5, 4.75), (18, 0.5))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'inner-mesh')
vs.EndSym()
vs.BeginSym("Rosetta-Outer")
vs.Symbol("Rosetta-Inner", (4.5, 2.75), 31.5)
vs.Locus((1.25, 9.75))
vs.EndSym()
vs.Symbol("Rosetta-Outer", (83.5, 41.25), 14)
h_so = vs.LNewObj()
vs.SetName(h_so, "outer-inst")
vs.Mirror(h_so, False, (83.5, 0), (83.5, 10))
vs.SetClass(h_so, "Rosetta-Ancestor")
vs.NameClass("Rosetta-Visible")
vs.BeginXtrd(0, 8)
vs.Rect((20, 45), (35, 30))
vs.EndXtrd()
h_v = vs.LNewObj()
vs.SetName(h_v, "box-visible")
vs.SetClass(h_v, "Rosetta-Visible")
vs.NameClass("None")
vs.HideClass("Rosetta-Ancestor")
rosetta_save_reopen()
