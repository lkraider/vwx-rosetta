# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.layer_scale.1_100
# family_id: document.layer_scale
# recipe_revision: 1
# recipe_path: recipes/document.layer_scale.1_100.json
# recipe_sha256: 490b4c085a4c5f9cd1bf65f5cf45020abb2bbb5c58dc6b255ba7b91b90ba28e8
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.layer_scale.1_100.vwx
#   sha256 7ea65bccf61dd4aab618489643519de39fbc9e1b13a07bccb2e957780574cb13. Run 20261018T113019-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.ActLayer()
vs.SetLScale(h_ly, 100)
vs.Rect((0, 1000), (2000, 0))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((0, 0), (2000, 0), -300, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.TextOrigin((0, 1500))
vs.TextSize(10)
vs.CreateText("Rosetta 1:100")
h_tx = vs.LNewObj()
vs.SetName(h_tx, "text-a")
rosetta_save_reopen()
