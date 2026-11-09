# Rosetta fixture recipe written in this repository for ROADMAP G3, unit and scale variants.
# case_id: document.layer_scale.1_1
# family_id: document.layer_scale
# recipe_revision: 1
# recipe_path: recipes/document.layer_scale.1_1.json
# recipe_sha256: 3a5f52701ccc4cfdc0a488ffc1071c962fd304a6722a55b1896cc84201675200
# native_verification: executed: driver/ui/make-sources.py batch g3-units, commit 6014e00, wrote sources/document.layer_scale.1_1.vwx
#   sha256 5b61703e8654c1a7381b45a4feb42f18eb42ef8db5b7fcecc17459cab1f643f9. Run 20261018T112858-ui-dxf exported that source.
# The capture adapter defines rosetta_checkpoint(id) and rosetta_save_reopen() before running this file.
import vs
h_ly = vs.ActLayer()
vs.SetLScale(h_ly, 1)
vs.Rect((0, 1000), (2000, 0))
h_rc = vs.LNewObj()
vs.SetName(h_rc, "rect-a")
vs.LinearDim((0, 0), (2000, 0), -300, 0, 0, 0, 0)
h_dm = vs.LNewObj()
vs.SetName(h_dm, "dim-a")
vs.TextOrigin((0, 1500))
vs.TextSize(10)
vs.CreateText("Rosetta 1:1")
h_tx = vs.LNewObj()
vs.SetName(h_tx, "text-a")
rosetta_save_reopen()
