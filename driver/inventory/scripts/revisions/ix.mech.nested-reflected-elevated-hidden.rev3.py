# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: ix.mech.nested-reflected-elevated-hidden
# family_id: container.symbol
# recipe_revision: 3
# base: driver/inventory/scripts/ix.mech.nested-reflected-elevated-hidden.py
# native_verification: unexecuted
# built: driver/ui/make-sources.py ran this file in Vectorworks 2027 on 2026-10-17 and wrote sources/ix.mech.nested-reflected-elevated-hidden.vwx,
#   sha256 6c1f63a8315116f52d5a4e73b35021f0e9a89df0781b52b56d2dafd0b430d540. native_verification names the vwx inventory check, which did not run.
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
vs.HideClass("Rosetta-Ancestor")
rosetta_save_reopen()
