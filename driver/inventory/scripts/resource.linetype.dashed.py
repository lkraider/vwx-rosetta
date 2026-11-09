# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: resource.linetype.dashed
# family_id: resource.linetype
# recipe_revision: 1
# recipe_path: recipes/resource.linetype.dashed.json
# recipe_sha256: f45b1f4032b686aa1e452742c48c9dbc3c828fffbc4df6d3702e366f777acfd0
# native_verification: executed: driver/ui/make-sources.py batch g3, commit 09f2dbe, wrote sources/resource.linetype.dashed.vwx
#   sha256 4e778e0da921cd7d9d91edd1a87da040f289b989d71d12adf534f85f53a6ede6. Run 20261018T094602-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.SetDashStyleN("Rosetta-Dash", False, 4, 0.1, 0.05, 0.02, 0.05)
lt = vs.Name2Index("Rosetta-Dash")
vs.MoveTo((0, 0))
vs.LineTo((50, 0))
h_ln = vs.LNewObj()
vs.SetName(h_ln, "line-dashed")
vs.SetLSN(h_ln, -lt)
vs.Rect((0, 30), (40, 10))
h_rd = vs.LNewObj()
vs.SetName(h_rd, "rect-dashed")
vs.SetLSN(h_rd, -lt)
rosetta_save_reopen()
