# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: container.symbol.nested_3d
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.nested_3d.json
# recipe_sha256: 7d3f424f8afc94e3c68f5c8f6c3806a27a9a61a531c2f3391efd1e305d98d324
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/container.symbol.nested_3d.vwx
#   sha256 1725d32a62ac42817f5f19bef23fb2473af8ce04d1b8687620e278855ac0bded. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSym("Rosetta-Inner-3D")
vs.BeginXtrd(0, 8)
vs.Rect((0, 6), (10, 0))
vs.EndXtrd()
vs.EndSym()
vs.BeginSym("Rosetta-Outer-3D")
vs.Symbol("Rosetta-Inner-3D", (5, 5), 0)
vs.EndSym()
vs.Symbol("Rosetta-Outer-3D", (40, 20), 0)
h_so = vs.LNewObj()
vs.SetName(h_so, "outer-inst-3d")
rosetta_save_reopen()
