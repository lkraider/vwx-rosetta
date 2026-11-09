# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: container.symbol.nested
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.nested.json
# recipe_sha256: dc025e0b7e7535fdd003ca9992295dc34cd21d0956b779b1fa1147997f89d58d
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/container.symbol.nested.vwx
#   sha256 e20a1bb1907ad6a4c1a975147da419cc4ddbb2a1f298c4e8191c43ef9c996329. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSym("Rosetta-Inner")
vs.Rect((0, 6), (10, 0))
vs.Oval((2, 5), (8, 1))
vs.EndSym()
vs.BeginSym("Rosetta-Outer")
vs.Symbol("Rosetta-Inner", (4, 3), 30)
vs.Rect((0, 20), (30, 0))
vs.EndSym()
vs.Symbol("Rosetta-Outer", (50, 20), 0)
h_so = vs.LNewObj()
vs.SetName(h_so, "outer-inst")
rosetta_save_reopen()
