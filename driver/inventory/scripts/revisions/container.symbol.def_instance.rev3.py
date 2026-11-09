# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: container.symbol.def_instance
# family_id: container.symbol
# recipe_revision: 3
# base: driver/inventory/scripts/revisions/container.symbol.def_instance.rev2.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/container.symbol.def_instance.vwx
#   sha256 8b618357bdc139d4831b5302688050b9076080400bab3521bdaf31de4f68508b. Run 20261017T170229-ui-gltf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSym("Rosetta-Sym-A")
vs.Rect((0, 9.5), (17.25, 0))
vs.Locus((3.5, 2.25))
vs.BeginXtrd(0, 3.5)
vs.Rect((19, 6.25), (25.5, 1.5))
vs.EndXtrd()
h_mx = vs.LNewObj()
vs.SetName(h_mx, 'sym-mesh')
vs.EndSym()
vs.Symbol("Rosetta-Sym-A", (42.5, 13.75), 23.5)
h_si = vs.LNewObj()
vs.SetName(h_si, "sym-inst-a")
rosetta_save_reopen()
