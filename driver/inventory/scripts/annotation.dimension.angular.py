# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: annotation.dimension.angular
# family_id: annotation.dimension
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.angular.json
# recipe_sha256: d7ab36f006a47f5a6ea115b92b4611e00d32f23bc187190ed2ac1dcb371e5ff0
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/annotation.dimension.angular.vwx
#   sha256 0a58ba6003049327d05cbcfaebfff4474177fdcdd9d1de32361ed219267e76ed. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.MoveTo((0, 0))
vs.LineTo((40, 0))
h_la = vs.LNewObj()
vs.SetName(h_la, "ray-a")
vs.MoveTo((0, 0))
vs.LineTo((0, 40))
h_lb = vs.LNewObj()
vs.SetName(h_lb, "ray-b")
vs.AngularDim((40, 0), (0, 40), (0, 0), 25, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-angular")
rosetta_save_reopen()
