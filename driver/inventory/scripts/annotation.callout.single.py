# Rosetta fixture recipe written in this repository for ROADMAP G3.
# case_id: annotation.callout.single
# family_id: annotation.callout
# recipe_revision: 1
# recipe_path: recipes/annotation.callout.single.json
# recipe_sha256: ec550821ca4dccb0f12f673ab3c744626c9000a5594eeb057869edb2b2fe9cfc
# native_verification: executed: driver/ui/make-sources.py batch g3, commit d617828, wrote sources/annotation.callout.single.vwx
#   sha256 07c656b3ff6751cd086c1a9dec88c12b226f3ae027e3d1af3523d064310e433e. Run 20261018T080007-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
vs.CreateCustomObjectN("Callout", (20, 10), 0, False)
h_co = vs.LNewObj()
vs.SetName(h_co, "callout-a")
vs.SetRField(h_co, "Callout", "Text", "Rosetta callout")
vs.ResetObject(h_co)
rosetta_save_reopen()
