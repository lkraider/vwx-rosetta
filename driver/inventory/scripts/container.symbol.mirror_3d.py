# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: container.symbol.mirror_3d
# family_id: container.symbol
# recipe_revision: 1
# recipe_path: recipes/container.symbol.mirror_3d.json
# recipe_sha256: a45042ebd8eb1534712c5906998120c5b0b2a83807ebcae8c03a46ec1f54afde
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/container.symbol.mirror_3d.vwx
#   sha256 a807e3f9f868a53709531841ddfdaaa73184e26303ffd6da3ee4c5021d9ad54c. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.BeginSym("Rosetta-Sym-3D")
vs.BeginXtrd(0, 12)
vs.Rect((0, 10), (20, 0))
vs.EndXtrd()
vs.BeginXtrd(0, 4)
vs.Rect((20, 4), (26, 0))
vs.EndXtrd()
vs.EndSym()
vs.Symbol("Rosetta-Sym-3D", (50, 20), 0)
h_sm = vs.LNewObj()
vs.SetName(h_sm, "sym-inst-mirrored")
vs.Mirror(h_sm, False, (50, 0), (50, 10))
rosetta_save_reopen()
