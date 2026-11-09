# Rosetta fixture recipe revision written in this repository. It makes None the active class
# before HideClass. NameClass makes its class the active class, and Vectorworks shows the active
# class whatever its visibility. One object sits in a hidden class. A second object, with a
# different shape and position, sits in a visible class.
# The base places the instance while Rosetta-3D is the active class, so the instance sits in
# Rosetta-3D. This revision places it in None, and HideClass hides only the 3D component.
# case_id: ix.mech.hybrid-2d-3d-class-override
# family_id: container.symbol
# recipe_revision: 3
# recipe_path: recipes/revisions/ix.mech.hybrid-2d-3d-class-override.rev3.json
# recipe_sha256: 287096da883fd8e6a636de75e2af36753159596fc73d9a2d4d8ff99f83b8e975
# base: driver/inventory/scripts/ix.mech.hybrid-2d-3d-class-override.py
# native_verification: executed: driver/ui/make-sources.py batch 1, commit 2527225, wrote sources/ix.mech.hybrid-2d-3d-class-override.vwx
#   sha256 4f1feb94fc8d5da55fc9dfa84a382de48d727e0060c99f3e6af07029ec54e4de. Run 20261018T051411-ui-dwg exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.NameClass("Rosetta-2D")
vs.NameClass("Rosetta-3D")
vs.BeginSym("Rosetta-Hybrid")
vs.Rect((0, 14.5), (23.75, 0))
h_r2 = vs.LNewObj()
vs.SetName(h_r2, "hyb-2d")
vs.SetClass(h_r2, "Rosetta-2D")
vs.BeginXtrd(0, 31.25)
vs.Rect((2.5, 11), (20.25, 3.5))
vs.EndXtrd()
h_x3 = vs.LNewObj()
vs.SetName(h_x3, "hyb-3d")
vs.SetClass(h_x3, "Rosetta-3D")
vs.EndSym()
vs.NameClass("None")
vs.Symbol("Rosetta-Hybrid", (57.5, 22.25), 0)
h_hi = vs.LNewObj()
vs.SetName(h_hi, "hybrid-inst")
vs.NameClass("Rosetta-Visible")
vs.BeginXtrd(0, 12)
vs.Oval((95, 30), (110, 15))
vs.EndXtrd()
h_v = vs.LNewObj()
vs.SetName(h_v, "cylinder-visible")
vs.SetClass(h_v, "Rosetta-Visible")
vs.NameClass("None")
vs.HideClass("Rosetta-3D")
rosetta_save_reopen()
