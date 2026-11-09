# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: annotation.dimension.associative
# family_id: annotation.dimension
# recipe_revision: 1
# recipe_path: recipes/annotation.dimension.associative.json
# recipe_sha256: 22029406e2e134f57aad5bf2657dfb4c480994767e255c0c830101671d80379b
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/annotation.dimension.associative.vwx
#   sha256 504c0166b166f89869733cc84f2e59eef5c88f132cddd012b7b016deed227cd0. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.Rect((0, 20), (40, 0))
h_ra = vs.LNewObj()
vs.SetName(h_ra, "rect-a")
vs.LinearDim((0, 0), (40, 0), -8, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-assoc")
vs.AssociateLinearDimension(h_dm, False)
rosetta_save_reopen()
