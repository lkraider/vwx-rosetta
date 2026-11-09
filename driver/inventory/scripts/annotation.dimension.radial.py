# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: annotation.dimension.radial
# family_id: annotation.dimension
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.radial.json
# recipe_sha256: a6ebebaf06649ec76c7b5b24bad2389e1ce09e3f39102c4df1c704b45e2f4126
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/annotation.dimension.radial.vwx
#   sha256 95773aed0ee5b3d48119d46177e2eafd8293d04cd7de2decc6483196c22b797a. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Oval((0, 20), (20, 0))
h_ci = vs.LNewObj()
vs.SetName(h_ci, "circle")
vs.CircularDim((10, 10), (20, 10), (0, 20), (20, 0), 5, 0, 0, 0, 0)
h_dr = vs.LNewObj()
vs.SetName(h_dr, "dim-radius")
vs.CircularDim((0, 10), (20, 10), (0, 20), (20, 0), 5, 1, 0, 0, 0)
h_dd = vs.LNewObj()
vs.SetName(h_dd, "dim-diameter")
rosetta_save_reopen()
