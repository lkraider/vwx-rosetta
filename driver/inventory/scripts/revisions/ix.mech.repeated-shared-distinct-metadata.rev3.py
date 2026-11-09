# Rosetta fixture recipe revision written in this repository for W17. It adds a 3D surface.
# case_id: ix.mech.repeated-shared-distinct-metadata
# family_id: container.symbol
# recipe_revision: 3
# base: driver/inventory/scripts/ix.mech.repeated-shared-distinct-metadata.py
# native_verification: executed: driver/ui/make-sources.py batch 4, commit 73a2296, wrote sources/ix.mech.repeated-shared-distinct-metadata.vwx
#   sha256 3ae6e2aabe5908f789cd20a7b4a2e44e2cb68017bcdf6d96e6b8303fa28d737f. Run 20261017T170229-ui-gltf exported that source.
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
vs.NewField("Rosetta-Occ", "Tag", "", 4, 0)
vs.Symbol("Rosetta-Sym-A", (31.5, 7.25), 0)
h_o0 = vs.LNewObj()
vs.SetName(h_o0, "occ-1")
vs.SetRecord(h_o0, "Rosetta-Occ")
vs.SetRField(h_o0, "Rosetta-Occ", "Tag", "A-1")
vs.Symbol("Rosetta-Sym-A", (78, 22.5), 41.25)
h_o1 = vs.LNewObj()
vs.SetName(h_o1, "occ-2")
vs.SetRecord(h_o1, "Rosetta-Occ")
vs.SetRField(h_o1, "Rosetta-Occ", "Tag", "B-2")
vs.Symbol("Rosetta-Sym-A", (-19.75, 54), 197.5)
h_o2 = vs.LNewObj()
vs.SetName(h_o2, "occ-3")
vs.SetRecord(h_o2, "Rosetta-Occ")
vs.SetRField(h_o2, "Rosetta-Occ", "Tag", "\u00c7-3")
rosetta_save_reopen()
